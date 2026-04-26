package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"github.com/spf13/cobra"
)

func processManager() error {
	var confFile string
	cmd := &cobra.Command{
		Use: "process-manager",
		RunE: func(cmd *cobra.Command, _ []string) error {
			return nil
		},
	}
	cmd.Flags().StringVar(&confFile, "conf", "", "path to the configuration file")

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	return cmd.ExecuteContext(ctx)
}

func main() {
	if err := processManager(); err != nil {
		fmt.Fprintf(os.Stderr, "%+v\n", err)
		os.Exit(1)
	}
}
