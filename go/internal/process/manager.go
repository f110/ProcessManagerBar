package process

import (
	"context"

	"google.golang.org/grpc"

	"go.f110.dev/ProcessManagerBar/proto"
)

type Manager struct {
	proto.UnimplementedProcessManagerServer
}

var _ proto.ProcessManagerServer = (*Manager)(nil)

func NewManager() *Manager {
	return &Manager{}
}

func (m *Manager) Status(ctx context.Context, status *proto.RequestStatus) (*proto.ResponseStatus, error) {
	//TODO implement me
	panic("implement me")
}

func (m *Manager) Configure(ctx context.Context, configure *proto.RequestConfigure) (*proto.ResponseConfigure, error) {
	//TODO implement me
	panic("implement me")
}

func (m *Manager) Start(ctx context.Context, start *proto.RequestStart) (*proto.ResponseStart, error) {
	//TODO implement me
	panic("implement me")
}

func (m *Manager) Stop(ctx context.Context, stop *proto.RequestStop) (*proto.ResponseStop, error) {
	//TODO implement me
	panic("implement me")
}

func (m *Manager) Restart(ctx context.Context, restart *proto.RequestRestart) (*proto.ResponseRestart, error) {
	//TODO implement me
	panic("implement me")
}

func (m *Manager) Logs(ctx context.Context, logs *proto.RequestLogs) (*proto.ResponseLogs, error) {
	//TODO implement me
	panic("implement me")
}

func (m *Manager) WatchLogs(logs *proto.RequestWatchLogs, g grpc.ServerStreamingServer[proto.ResponseWatchLogs]) error {
	//TODO implement me
	panic("implement me")
}

type Process struct{}
