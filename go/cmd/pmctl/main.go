package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"text/tabwriter"
	"time"

	"github.com/spf13/cobra"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials/insecure"

	"go.f110.dev/ProcessManagerBar/proto"
)

const defaultServer = "unix:///tmp/process-manager.sock"

func main() {
	if err := newRootCmd().Execute(); err != nil {
		fmt.Fprintf(os.Stderr, "%+v\n", err)
		os.Exit(1)
	}
}

func newRootCmd() *cobra.Command {
	var server string
	root := &cobra.Command{
		Use:           "pmctl",
		Short:         "Client for the process-manager daemon",
		SilenceUsage:  true,
		SilenceErrors: true,
	}
	root.PersistentFlags().StringVar(&server, "server", defaultServer, "server address (tcp://host:port or unix:///path/to/sock)")

	root.AddCommand(newStatusCmd(&server))
	root.AddCommand(newRestartCmd(&server))
	root.AddCommand(newLogsCmd(&server))
	root.AddCommand(newReloadCmd(&server))
	return root
}

func newStatusCmd(server *string) *cobra.Command {
	return &cobra.Command{
		Use:   "status [name]",
		Short: "Show process status",
		Args:  cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			name := ""
			if len(args) == 1 {
				name = args[0]
			}
			ctx, cancel := context.WithTimeout(cmd.Context(), 5*time.Second)
			defer cancel()
			return runStatus(ctx, *server, name, cmd.OutOrStdout())
		},
	}
}

func newRestartCmd(server *string) *cobra.Command {
	return &cobra.Command{
		Use:   "restart <name>",
		Short: "Restart a process",
		Args:  cobra.ExactArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx, cancel := context.WithTimeout(cmd.Context(), 10*time.Second)
			defer cancel()
			return runRestart(ctx, *server, args[0], cmd.OutOrStdout())
		},
	}
}

func newLogsCmd(server *string) *cobra.Command {
	var follow bool
	c := &cobra.Command{
		Use:   "logs [name]",
		Short: "Print captured logs (omit name for process-manager's own log)",
		Args:  cobra.MaximumNArgs(1),
		RunE: func(cmd *cobra.Command, args []string) error {
			name := ""
			if len(args) == 1 {
				name = args[0]
			}
			if follow {
				ctx, stop := signal.NotifyContext(cmd.Context(), os.Interrupt, syscall.SIGTERM)
				defer stop()
				return runLogsFollow(ctx, *server, name, cmd.OutOrStdout())
			}
			ctx, cancel := context.WithTimeout(cmd.Context(), 5*time.Second)
			defer cancel()
			return runLogs(ctx, *server, name, cmd.OutOrStdout())
		},
	}
	c.Flags().BoolVarP(&follow, "follow", "f", false, "follow log output (tail -f)")
	return c
}

func newReloadCmd(server *string) *cobra.Command {
	return &cobra.Command{
		Use:   "reload",
		Short: "Reload the configuration file",
		Args:  cobra.NoArgs,
		RunE: func(cmd *cobra.Command, _ []string) error {
			ctx, cancel := context.WithTimeout(cmd.Context(), 10*time.Second)
			defer cancel()
			return runReload(ctx, *server, cmd.OutOrStdout())
		},
	}
}

func runStatus(ctx context.Context, server, name string, out io.Writer) error {
	conn, err := dial(server)
	if err != nil {
		return err
	}
	defer conn.Close()

	client := proto.NewProcessManagerClient(conn)
	req := proto.RequestStatus_builder{}
	if name != "" {
		req.Name = &name
	}
	resp, err := client.Status(ctx, req.Build())
	if err != nil {
		return err
	}

	tw := tabwriter.NewWriter(out, 0, 0, 2, ' ', 0)
	fmt.Fprintln(tw, "NAME\tSTATE\tSTARTED")
	for _, ps := range resp.GetProcesses() {
		started := "-"
		if ts := ps.GetStartedAt(); ts != nil {
			started = ts.AsTime().Local().Format(time.RFC3339)
		}
		fmt.Fprintf(tw, "%s\t%s\t%s\n", ps.GetName(), formatState(ps.GetState()), started)
	}
	return tw.Flush()
}

func runReload(ctx context.Context, server string, out io.Writer) error {
	conn, err := dial(server)
	if err != nil {
		return err
	}
	defer conn.Close()

	client := proto.NewProcessManagerClient(conn)
	resp, err := client.Reload(ctx, proto.RequestReload_builder{}.Build())
	if err != nil {
		return err
	}
	printReloadGroup(out, "added", resp.GetAdded())
	printReloadGroup(out, "removed", resp.GetRemoved())
	printReloadGroup(out, "changed", resp.GetChanged())
	printReloadGroup(out, "unchanged", resp.GetUnchanged())
	return nil
}

func printReloadGroup(out io.Writer, label string, names []string) {
	if len(names) == 0 {
		fmt.Fprintf(out, "%s: (none)\n", label)
		return
	}
	fmt.Fprintf(out, "%s: %s\n", label, strings.Join(names, ", "))
}

func runRestart(ctx context.Context, server, name string, out io.Writer) error {
	conn, err := dial(server)
	if err != nil {
		return err
	}
	defer conn.Close()

	client := proto.NewProcessManagerClient(conn)
	req := proto.RequestRestart_builder{Name: &name}.Build()
	if _, err := client.Restart(ctx, req); err != nil {
		return err
	}
	fmt.Fprintf(out, "restarted %s\n", name)
	return nil
}

func runLogs(ctx context.Context, server, name string, out io.Writer) error {
	conn, err := dial(server)
	if err != nil {
		return err
	}
	defer conn.Close()

	client := proto.NewProcessManagerClient(conn)
	resp, err := client.Logs(ctx, proto.RequestLogs_builder{Name: &name}.Build())
	if err != nil {
		return err
	}
	_, err = out.Write(resp.GetContent())
	return err
}

func runLogsFollow(ctx context.Context, server, name string, out io.Writer) error {
	conn, err := dial(server)
	if err != nil {
		return err
	}
	defer conn.Close()

	client := proto.NewProcessManagerClient(conn)
	stream, err := client.WatchLogs(ctx, proto.RequestWatchLogs_builder{Name: &name}.Build())
	if err != nil {
		return err
	}
	for {
		msg, err := stream.Recv()
		if err == io.EOF {
			return nil
		}
		if err != nil {
			if errors.Is(ctx.Err(), context.Canceled) {
				return nil
			}
			return err
		}
		if _, werr := out.Write(msg.GetContent()); werr != nil {
			return werr
		}
	}
}

func formatState(s proto.ProcessState) string {
	switch s {
	case proto.ProcessState_PROCESS_STATE_RUNNING:
		return "running"
	case proto.ProcessState_PROCESS_STATE_STOP:
		return "stopped"
	case proto.ProcessState_PROCESS_STATE_NEEDS_RESTART:
		return "needs-restart"
	default:
		return "unknown"
	}
}

func dial(server string) (*grpc.ClientConn, error) {
	scheme, target, ok := strings.Cut(server, "://")
	if !ok {
		return nil, fmt.Errorf("invalid server address: %s", server)
	}
	var endpoint string
	switch scheme {
	case "tcp", "tcp4", "tcp6":
		endpoint = "passthrough:///" + target
	case "unix":
		endpoint = "unix://" + target
	default:
		return nil, fmt.Errorf("unsupported scheme: %s", scheme)
	}
	return grpc.NewClient(endpoint, grpc.WithTransportCredentials(insecure.NewCredentials()))
}
