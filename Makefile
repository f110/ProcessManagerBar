PROTOC = protoc

gen: proto/process.pb.go proto/process_grpc.pb.go

proto/process.pb.go: proto/process.proto
	$(PROTOC) --go_out=. --go_opt=paths=source_relative $^

proto/process_grpc.pb.go: proto/process.proto
	$(PROTOC) --go-grpc_out=. --go-grpc_opt=paths=source_relative $^
