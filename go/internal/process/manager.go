package process

import (
	"context"
	"fmt"
	"io"
	"sync"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/types/known/timestamppb"

	"go.f110.dev/ProcessManagerBar/go/internal/config"
	"go.f110.dev/ProcessManagerBar/proto"
)

type Manager struct {
	proto.UnimplementedProcessManagerServer

	mu        sync.RWMutex
	processes []*managedProcess
	byName    map[string]*managedProcess
	sysLog    *logSink
}

var _ proto.ProcessManagerServer = (*Manager)(nil)

func NewManager(cfg *config.Configuration) *Manager {
	m := &Manager{
		byName: make(map[string]*managedProcess),
		sysLog: newLogSink(cfg.MaxLogLines),
	}
	for _, pc := range cfg.Processes {
		mp := newManagedProcess(pc, cfg.MaxLogLines)
		m.processes = append(m.processes, mp)
		m.byName[pc.Name] = mp
	}
	return m
}

// SystemLogWriter returns a writer that captures process-manager's own log
// output. Wire it up via log.SetOutput so Logs/WatchLogs with an empty name
// can serve those messages.
func (m *Manager) SystemLogWriter() io.Writer {
	return m.sysLog
}

func (m *Manager) StartAll() {
	m.mu.RLock()
	procs := append([]*managedProcess(nil), m.processes...)
	m.mu.RUnlock()
	for _, p := range procs {
		if err := p.Start(); err != nil {
			fmt.Printf("[%s] start failed: %v\n", p.Name(), err)
		}
	}
}

func (m *Manager) StopAll() {
	m.mu.RLock()
	procs := append([]*managedProcess(nil), m.processes...)
	m.mu.RUnlock()
	for _, p := range procs {
		_ = p.Stop()
	}
}

func (m *Manager) Status(_ context.Context, req *proto.RequestStatus) (*proto.ResponseStatus, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()

	name := req.GetName()
	var targets []*managedProcess
	if name == "" {
		targets = append([]*managedProcess(nil), m.processes...)
	} else {
		p, ok := m.byName[name]
		if !ok {
			return nil, status.Errorf(codes.NotFound, "process %q not found", name)
		}
		targets = []*managedProcess{p}
	}

	statuses := make([]*proto.ProcessStatus, 0, len(targets))
	for _, p := range targets {
		running, needsRestart, startedAt := p.State()
		st := proto.ProcessState_PROCESS_STATE_STOP
		if running {
			st = proto.ProcessState_PROCESS_STATE_RUNNING
			if needsRestart {
				st = proto.ProcessState_PROCESS_STATE_NEEDS_RESTART
			}
		}
		ps := proto.ProcessStatus_builder{
			Name:  new(p.Name()),
			State: &st,
		}
		if !startedAt.IsZero() {
			ps.StartedAt = timestamppb.New(startedAt)
		}
		statuses = append(statuses, ps.Build())
	}
	return proto.ResponseStatus_builder{Processes: statuses}.Build(), nil
}

func (m *Manager) Start(_ context.Context, req *proto.RequestStart) (*proto.ResponseStart, error) {
	p, err := m.lookup(req.GetName())
	if err != nil {
		return nil, err
	}
	if err := p.Start(); err != nil {
		return nil, status.Error(codes.Internal, err.Error())
	}
	ok := true
	return proto.ResponseStart_builder{Ok: &ok}.Build(), nil
}

func (m *Manager) Stop(_ context.Context, req *proto.RequestStop) (*proto.ResponseStop, error) {
	p, err := m.lookup(req.GetName())
	if err != nil {
		return nil, err
	}
	if err := p.Stop(); err != nil {
		return nil, status.Error(codes.Internal, err.Error())
	}
	ok := true
	return proto.ResponseStop_builder{Ok: &ok}.Build(), nil
}

func (m *Manager) Restart(_ context.Context, req *proto.RequestRestart) (*proto.ResponseRestart, error) {
	p, err := m.lookup(req.GetName())
	if err != nil {
		return nil, err
	}
	if err := p.Restart(); err != nil {
		return nil, status.Error(codes.Internal, err.Error())
	}
	return proto.ResponseRestart_builder{}.Build(), nil
}

func (m *Manager) Logs(_ context.Context, req *proto.RequestLogs) (*proto.ResponseLogs, error) {
	snapshot, err := m.snapshotFor(req.GetName())
	if err != nil {
		return nil, err
	}
	return proto.ResponseLogs_builder{Content: snapshot}.Build(), nil
}

func (m *Manager) WatchLogs(req *proto.RequestWatchLogs, stream grpc.ServerStreamingServer[proto.ResponseWatchLogs]) error {
	sink, err := m.sinkFor(req.GetName())
	if err != nil {
		return err
	}

	if snapshot := sink.Snapshot(); len(snapshot) > 0 {
		if err := stream.Send(proto.ResponseWatchLogs_builder{Content: snapshot}.Build()); err != nil {
			return err
		}
	}

	ch, cancel := sink.Subscribe()
	defer cancel()

	ctx := stream.Context()
	for {
		select {
		case <-ctx.Done():
			return nil
		case chunk, ok := <-ch:
			if !ok {
				return nil
			}
			if err := stream.Send(proto.ResponseWatchLogs_builder{Content: chunk}.Build()); err != nil {
				return err
			}
		}
	}
}

func (m *Manager) sinkFor(name string) (*logSink, error) {
	if name == "" {
		return m.sysLog, nil
	}
	p, err := m.lookup(name)
	if err != nil {
		return nil, err
	}
	return p.logSink, nil
}

func (m *Manager) snapshotFor(name string) ([]byte, error) {
	sink, err := m.sinkFor(name)
	if err != nil {
		return nil, err
	}
	return sink.Snapshot(), nil
}

func (m *Manager) lookup(name string) (*managedProcess, error) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	p, ok := m.byName[name]
	if !ok {
		return nil, status.Errorf(codes.NotFound, "process %q not found", name)
	}
	return p, nil
}
