package process

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"github.com/fsnotify/fsnotify"

	"go.f110.dev/ProcessManagerBar/go/internal/config"
)

var ignoredDirNames = map[string]struct{}{
	".git":         {},
	"node_modules": {},
	"vendor":       {},
	".build":       {},
	"__pycache__":  {},
	".svn":         {},
	".hg":          {},
}

type processState int

const (
	stateStopped processState = iota
	stateRunning
	stateStopping
	stateRestarting
	stateNeedsRestart
)

type managedProcess struct {
	cfg         config.ProcessConfig
	maxLogLines int

	mu         sync.Mutex
	cmd        *exec.Cmd
	startedAt  time.Time
	logFile    *os.File
	logSink    *logSink
	watcher    *fsnotify.Watcher
	cancelWait context.CancelFunc

	state processState // guarded by mu
}

func newManagedProcess(cfg config.ProcessConfig, maxLogLines int) *managedProcess {
	return &managedProcess{
		cfg:         cfg,
		maxLogLines: maxLogLines,
		logSink:     newLogSink(maxLogLines),
	}
}

func (p *managedProcess) Name() string {
	return p.cfg.Name
}

func (p *managedProcess) State() (running bool, needsRestart bool, startedAt time.Time) {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.state != stateStopped, p.state == stateNeedsRestart, p.startedAt
}

func (p *managedProcess) LogSnapshot() []byte {
	return p.logSink.Snapshot()
}

func (p *managedProcess) SubscribeLogs() (<-chan []byte, func()) {
	return p.logSink.Subscribe()
}

func (p *managedProcess) Start() error {
	p.mu.Lock()
	if p.state != stateStopped {
		p.mu.Unlock()
		return nil
	}
	if len(p.cfg.Command) == 0 {
		p.mu.Unlock()
		return errors.New("command is empty")
	}

	expandedDir := expandTilde(p.cfg.Dir)
	executable := expandTilde(p.cfg.Command[0])

	resolved, err := resolveExecutable(executable, expandedDir)
	if err != nil {
		p.mu.Unlock()
		return err
	}

	args := make([]string, 0, len(p.cfg.Command)-1)
	for _, a := range p.cfg.Command[1:] {
		args = append(args, expandTilde(strings.ReplaceAll(a, "$DIR", expandedDir)))
	}

	cmd := exec.Command(resolved, args...)
	cmd.Dir = expandedDir
	cmd.Env = os.Environ()
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}

	if p.cfg.LogFile != "" {
		expandedPath := expandTilde(p.cfg.LogFile)
		if err := os.MkdirAll(filepath.Dir(expandedPath), 0o755); err != nil {
			p.mu.Unlock()
			return fmt.Errorf("create log dir: %w", err)
		}
		f, err := os.OpenFile(expandedPath, os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0o644)
		if err != nil {
			p.mu.Unlock()
			return fmt.Errorf("open log file: %w", err)
		}
		p.logFile = f
	}

	p.logSink.setLogFile(p.logFile)
	cmd.Stdout = p.logSink
	cmd.Stderr = p.logSink

	log.Printf("[%s] starting process: %s %s", p.cfg.Name, resolved, strings.Join(args, " "))
	if err := cmd.Start(); err != nil {
		if p.logFile != nil {
			p.logFile.Close()
			p.logFile = nil
		}
		p.mu.Unlock()
		return fmt.Errorf("start process: %w", err)
	}

	p.cmd = cmd
	p.state = stateRunning
	p.startedAt = time.Now()
	ctx, cancel := context.WithCancel(context.Background())
	p.cancelWait = cancel

	log.Printf("[%s] process started (pid=%d)", p.cfg.Name, cmd.Process.Pid)

	if p.cfg.Watch {
		if err := p.startWatchingLocked(expandedDir); err != nil {
			log.Printf("[%s] file watch failed: %v", p.cfg.Name, err)
		}
	}

	p.mu.Unlock()

	go p.waitProcess(ctx, cmd)
	return nil
}

func (p *managedProcess) waitProcess(ctx context.Context, cmd *exec.Cmd) {
	err := cmd.Wait()

	p.mu.Lock()
	exitCode := 0
	if cmd.ProcessState != nil {
		exitCode = cmd.ProcessState.ExitCode()
	}
	p.cmd = nil
	p.startedAt = time.Time{}
	p.stopWatchingLocked()
	if p.logFile != nil {
		p.logFile.Close()
		p.logFile = nil
		p.logSink.setLogFile(nil)
	}

	prev := p.state
	p.state = stateStopped
	p.mu.Unlock()

	select {
	case <-ctx.Done():
		return
	default:
	}

	log.Printf("[%s] process stopped (exit=%d, err=%v)", p.cfg.Name, exitCode, err)

	if prev == stateRestarting {
		if err := p.Start(); err != nil {
			log.Printf("[%s] restart failed: %v", p.cfg.Name, err)
		}
		return
	}
	if prev == stateStopping {
		return
	}

	if exitCode != 0 || err != nil {
		time.AfterFunc(2*time.Second, func() {
			p.mu.Lock()
			running := p.state != stateStopped
			p.mu.Unlock()
			if running {
				return
			}
			if err := p.Start(); err != nil {
				log.Printf("[%s] auto-restart failed: %v", p.cfg.Name, err)
			}
		})
	}
}

func (p *managedProcess) Stop() error {
	p.mu.Lock()
	if p.state == stateStopped || p.cmd == nil {
		p.mu.Unlock()
		return nil
	}
	p.state = stateStopping
	cmd := p.cmd
	p.mu.Unlock()
	return p.terminate(cmd)
}

func (p *managedProcess) Restart() error {
	p.mu.Lock()
	if p.state == stateStopped || p.cmd == nil {
		p.mu.Unlock()
		return p.Start()
	}
	p.state = stateRestarting
	cmd := p.cmd
	p.mu.Unlock()
	return p.terminate(cmd)
}

func (p *managedProcess) terminate(cmd *exec.Cmd) error {
	if cmd.Process == nil {
		return nil
	}
	pid := cmd.Process.Pid
	if err := syscall.Kill(-pid, syscall.SIGTERM); err != nil {
		_ = cmd.Process.Signal(syscall.SIGTERM)
	}
	go func() {
		time.Sleep(3 * time.Second)
		p.mu.Lock()
		stillRunning := p.cmd == cmd && p.state != stateStopped
		p.mu.Unlock()
		if stillRunning {
			_ = syscall.Kill(-pid, syscall.SIGKILL)
		}
	}()
	return nil
}

func (p *managedProcess) markNeedsRestart() {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.state == stateRunning {
		p.state = stateNeedsRestart
	}
}

// startWatchingLocked must be called with p.mu held.
func (p *managedProcess) startWatchingLocked(dir string) error {
	w, err := fsnotify.NewWatcher()
	if err != nil {
		return err
	}
	if err := addWatchRecursive(w, dir); err != nil {
		w.Close()
		return err
	}
	p.watcher = w
	go p.watchLoop(w)
	return nil
}

// stopWatchingLocked must be called with p.mu held.
func (p *managedProcess) stopWatchingLocked() {
	if p.watcher != nil {
		p.watcher.Close()
		p.watcher = nil
	}
}

func (p *managedProcess) watchLoop(w *fsnotify.Watcher) {
	for {
		select {
		case ev, ok := <-w.Events:
			if !ok {
				return
			}
			if shouldIgnorePath(ev.Name) {
				continue
			}
			if ev.Op&fsnotify.Create != 0 {
				if info, err := os.Stat(ev.Name); err == nil && info.IsDir() {
					_ = addWatchRecursive(w, ev.Name)
				}
			}
			log.Printf("[%s] file changed: %s", p.cfg.Name, ev.Name)
			if ev.Op&(fsnotify.Write|fsnotify.Create|fsnotify.Remove|fsnotify.Rename) != 0 {
				p.markNeedsRestart()
			}
		case err, ok := <-w.Errors:
			if !ok {
				return
			}
			log.Printf("[%s] watch error: %v", p.cfg.Name, err)
		}
	}
}

func addWatchRecursive(w *fsnotify.Watcher, root string) error {
	return filepath.WalkDir(root, func(path string, d os.DirEntry, err error) error {
		if err != nil {
			return nil
		}
		if !d.IsDir() {
			return nil
		}
		if path != root {
			if _, ignore := ignoredDirNames[d.Name()]; ignore {
				return filepath.SkipDir
			}
		}
		if err := w.Add(path); err != nil {
			return nil
		}
		return nil
	})
}

func shouldIgnorePath(path string) bool {
	for _, part := range strings.Split(path, string(os.PathSeparator)) {
		if _, ignore := ignoredDirNames[part]; ignore {
			return true
		}
	}
	return false
}

func resolveExecutable(executable, dir string) (string, error) {
	if strings.Contains(executable, "/") {
		full := executable
		if !filepath.IsAbs(full) {
			full = filepath.Join(dir, full)
		}
		if !isExecutable(full) {
			return "", fmt.Errorf("executable not found: %s", executable)
		}
		return full, nil
	}
	resolved, err := exec.LookPath(executable)
	if err != nil {
		return "", fmt.Errorf("executable not found in PATH: %s", executable)
	}
	return resolved, nil
}

func isExecutable(path string) bool {
	info, err := os.Stat(path)
	if err != nil || info.IsDir() {
		return false
	}
	return info.Mode()&0o111 != 0
}

func expandTilde(path string) string {
	if !strings.HasPrefix(path, "~") {
		return path
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return path
	}
	if path == "~" {
		return home
	}
	if strings.HasPrefix(path, "~/") {
		return filepath.Join(home, path[2:])
	}
	return path
}

// logSink captures process stdout/stderr, writes it to an optional log file,
// and keeps a rolling buffer of the last N lines for retrieval.
type logSink struct {
	mu       sync.Mutex
	maxLines int
	buf      bytes.Buffer
	logFile  *os.File
	subs     map[chan []byte]struct{}
}

func newLogSink(maxLines int) *logSink {
	if maxLines <= 0 {
		maxLines = config.DefaultMaxLogLines
	}
	return &logSink{maxLines: maxLines, subs: make(map[chan []byte]struct{})}
}

func (s *logSink) setLogFile(f *os.File) {
	s.mu.Lock()
	s.logFile = f
	s.mu.Unlock()
}

func (s *logSink) Write(p []byte) (int, error) {
	s.mu.Lock()
	s.buf.Write(p)
	trimBufferLocked(&s.buf, s.maxLines)
	f := s.logFile
	if len(s.subs) > 0 {
		chunk := make([]byte, len(p))
		copy(chunk, p)
		for ch := range s.subs {
			select {
			case ch <- chunk:
			default:
			}
		}
	}
	s.mu.Unlock()
	if f != nil {
		_, _ = f.Write(p)
	}
	return len(p), nil
}

func (s *logSink) Snapshot() []byte {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make([]byte, s.buf.Len())
	copy(out, s.buf.Bytes())
	return out
}

// Subscribe returns a channel that receives newly written log chunks until the
// returned cancel function is called. Slow subscribers will drop chunks.
func (s *logSink) Subscribe() (<-chan []byte, func()) {
	ch := make(chan []byte, 64)
	s.mu.Lock()
	s.subs[ch] = struct{}{}
	s.mu.Unlock()
	cancel := func() {
		s.mu.Lock()
		if _, ok := s.subs[ch]; ok {
			delete(s.subs, ch)
			close(ch)
		}
		s.mu.Unlock()
	}
	return ch, cancel
}

func trimBufferLocked(buf *bytes.Buffer, maxLines int) {
	if maxLines <= 0 {
		return
	}
	data := buf.Bytes()
	count := bytes.Count(data, []byte{'\n'})
	if count <= maxLines {
		return
	}
	toSkip := count - maxLines
	idx := 0
	for skipped := 0; skipped < toSkip; {
		nl := bytes.IndexByte(data[idx:], '\n')
		if nl < 0 {
			return
		}
		idx += nl + 1
		skipped++
	}
	remaining := make([]byte, len(data)-idx)
	copy(remaining, data[idx:])
	buf.Reset()
	buf.Write(remaining)
}

// Ensure io.Writer interface is satisfied.
var _ io.Writer = (*logSink)(nil)
