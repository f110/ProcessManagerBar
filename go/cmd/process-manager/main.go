package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/spf13/cobra"
	"google.golang.org/grpc"

	"go.f110.dev/ProcessManagerBar/go/internal/config"
	"go.f110.dev/ProcessManagerBar/go/internal/process"
	"go.f110.dev/ProcessManagerBar/proto"
)

func processManager() error {
	var confFile string
	var listen string
	cmd := &cobra.Command{
		Use:   "process-manager",
		Short: "Run and manage processes defined in a configuration file",
		RunE: func(cmd *cobra.Command, _ []string) error {
			if confFile == "" {
				return errors.New("--conf is required")
			}
			cfg, err := config.Read(confFile)
			if err != nil {
				return err
			}

			if !cmd.Flags().Changed("listen") && cfg.Server != "" {
				listen = cfg.Server
			}

			ln, cleanup, err := openListener(listen)
			if err != nil {
				return err
			}
			defer cleanup()

			mgr := process.NewManager(cfg)
			log.SetOutput(io.MultiWriter(os.Stderr, mgr.SystemLogWriter()))

			grpcServer := grpc.NewServer()
			proto.RegisterProcessManagerServer(grpcServer, mgr)

			serverErrCh := make(chan error, 1)
			go func() {
				log.Printf("gRPC server listening on %s", listen)
				if err := grpcServer.Serve(ln); err != nil {
					serverErrCh <- err
				}
				close(serverErrCh)
			}()

			select {
			case <-cmd.Context().Done():
				log.Printf("shutting down")
			case err := <-serverErrCh:
				if err != nil {
					log.Printf("gRPC server error: %v", err)
				}
			}

			stopped := make(chan struct{})
			go func() {
				defer close(stopped)
				grpcServer.GracefulStop()
			}()
			select {
			case <-stopped:
			case <-time.After(5 * time.Second):
				log.Printf("force shutting down gRPC server")
				grpcServer.Stop()
			}
			mgr.StopAll()
			return nil
		},
	}
	cmd.Flags().StringVar(&confFile, "conf", "", "path to the configuration file")
	cmd.Flags().StringVar(&listen, "listen", "unix:///tmp/process-manager.sock", "listen address (tcp://host:port or unix:///path/to/sock)")

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	return cmd.ExecuteContext(ctx)
}

func openListener(addr string) (net.Listener, func(), error) {
	scheme, target, ok := strings.Cut(addr, "://")
	if !ok {
		return nil, nil, fmt.Errorf("invalid listen address: %s", addr)
	}
	switch scheme {
	case "tcp", "tcp4", "tcp6":
		ln, err := net.Listen(scheme, target)
		if err != nil {
			return nil, nil, err
		}
		return ln, func() {}, nil
	case "unix":
		_ = os.Remove(target)
		ln, err := net.Listen("unix", target)
		if err != nil {
			return nil, nil, err
		}
		return ln, func() { _ = os.Remove(target) }, nil
	default:
		return nil, nil, fmt.Errorf("unsupported scheme: %s", scheme)
	}
}

func main() {
	if err := processManager(); err != nil {
		fmt.Fprintf(os.Stderr, "%+v\n", err)
		os.Exit(1)
	}
}
