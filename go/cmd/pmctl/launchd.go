package main

import (
	"bytes"
	"encoding/xml"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"text/template"

	"github.com/spf13/cobra"
)

const defaultLaunchdLabel = "dev.f110.process-manager"

func newLaunchdPlistCmd() *cobra.Command {
	var (
		label     string
		binary    string
		confFile  string
		listen    string
		output    string
		stdoutLog string
		stderrLog string
		force     bool
	)
	c := &cobra.Command{
		Use:   "load",
		Short: "Write a launchd plist for the process-manager daemon",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			if confFile == "" {
				return fmt.Errorf("--conf is required")
			}
			absConf, err := filepath.Abs(confFile)
			if err != nil {
				return fmt.Errorf("resolve --conf: %w", err)
			}
			absBin, err := resolveProcessManagerBinary(binary)
			if err != nil {
				return err
			}

			args := []string{absBin, "--conf", absConf}
			if listen != "" {
				args = append(args, "--listen", listen)
			}

			opts := plistOptions{
				Label:             label,
				ProgramArguments:  args,
				StandardOutPath:   stdoutLog,
				StandardErrorPath: stderrLog,
			}
			buf := &bytes.Buffer{}
			if err := writeLaunchdPlist(buf, opts); err != nil {
				return err
			}

			if output == "-" {
				_, err := cmd.OutOrStdout().Write(buf.Bytes())
				return err
			}

			outPath := output
			if outPath == "" {
				home, err := os.UserHomeDir()
				if err != nil {
					return fmt.Errorf("resolve home directory: %w", err)
				}
				outPath = filepath.Join(home, "Library", "LaunchAgents", label+".plist")
			}
			if !force {
				if _, err := os.Stat(outPath); err == nil {
					return fmt.Errorf("file already exists: %s (use --force to overwrite)", outPath)
				} else if !os.IsNotExist(err) {
					return fmt.Errorf("stat %s: %w", outPath, err)
				}
			}
			if err := os.MkdirAll(filepath.Dir(outPath), 0o755); err != nil {
				return fmt.Errorf("create directory: %w", err)
			}
			if err := os.WriteFile(outPath, buf.Bytes(), 0o644); err != nil {
				return fmt.Errorf("write plist: %w", err)
			}
			fmt.Fprintf(cmd.OutOrStdout(), "wrote %s\n", outPath)
			return nil
		},
	}
	c.Flags().StringVar(&label, "label", defaultLaunchdLabel, "launchd job label")
	c.Flags().StringVar(&binary, "binary", "", "path to the process-manager binary (default: look up process-manager in PATH)")
	c.Flags().StringVar(&confFile, "conf", "", "path to the process-manager configuration file (required)")
	c.Flags().StringVar(&listen, "listen", "", "listen address passed to the daemon (omit to use the daemon's default)")
	c.Flags().StringVarP(&output, "output", "o", "", "output path (default: ~/Library/LaunchAgents/<label>.plist; \"-\" writes to stdout)")
	c.Flags().StringVar(&stdoutLog, "stdout-log", "", "value for StandardOutPath in the plist")
	c.Flags().StringVar(&stderrLog, "stderr-log", "", "value for StandardErrorPath in the plist")
	c.Flags().BoolVar(&force, "force", false, "overwrite the output file if it already exists")
	return c
}

func resolveProcessManagerBinary(explicit string) (string, error) {
	if explicit != "" {
		abs, err := filepath.Abs(explicit)
		if err != nil {
			return "", fmt.Errorf("resolve --binary: %w", err)
		}
		if _, err := os.Stat(abs); err != nil {
			return "", fmt.Errorf("stat --binary: %w", err)
		}
		return abs, nil
	}
	p, err := exec.LookPath("process-manager")
	if err != nil {
		return "", fmt.Errorf("process-manager not found in PATH; specify --binary")
	}
	return filepath.Abs(p)
}

type plistOptions struct {
	Label             string
	ProgramArguments  []string
	StandardOutPath   string
	StandardErrorPath string
}

const launchdPlistTemplate = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>{{ xmlescape .Label }}</string>
  <key>ProgramArguments</key>
  <array>
{{- range .ProgramArguments }}
    <string>{{ xmlescape . }}</string>
{{- end }}
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
{{- if .StandardOutPath }}
  <key>StandardOutPath</key>
  <string>{{ xmlescape .StandardOutPath }}</string>
{{- end }}
{{- if .StandardErrorPath }}
  <key>StandardErrorPath</key>
  <string>{{ xmlescape .StandardErrorPath }}</string>
{{- end }}
</dict>
</plist>
`

func writeLaunchdPlist(w io.Writer, opts plistOptions) error {
	t := template.Must(template.New("plist").Funcs(template.FuncMap{
		"xmlescape": func(s string) (string, error) {
			var buf bytes.Buffer
			if err := xml.EscapeText(&buf, []byte(s)); err != nil {
				return "", err
			}
			return buf.String(), nil
		},
	}).Parse(launchdPlistTemplate))
	return t.Execute(w, opts)
}
