PROTOC = protoc

gen: proto/process.pb.go proto/process_grpc.pb.go ProcessManagerBar/Generated/process.pb.swift ProcessManagerBar/Generated/process.grpc.swift

proto/process.pb.go: proto/process.proto
	$(PROTOC) --go_out=. --go_opt=paths=source_relative $^

proto/process_grpc.pb.go: proto/process.proto
	$(PROTOC) --go-grpc_out=. --go-grpc_opt=paths=source_relative $^

ProcessManagerBar/Generated/process.pb.swift: proto/process.proto
	mkdir -p ProcessManagerBar/Generated
	$(PROTOC) --swift_out=ProcessManagerBar/Generated --swift_opt=Visibility=Public $<
	mv ProcessManagerBar/Generated/proto/process.pb.swift $@
	rmdir ProcessManagerBar/Generated/proto 2>/dev/null || true

ProcessManagerBar/Generated/process.grpc.swift: proto/process.proto
	mkdir -p ProcessManagerBar/Generated
	$(PROTOC) --grpc-swift-2_out=ProcessManagerBar/Generated --grpc-swift-2_opt=Visibility=Public,Client=true,Server=false $<
	mv ProcessManagerBar/Generated/proto/process.grpc.swift $@
	rmdir ProcessManagerBar/Generated/proto 2>/dev/null || true

.PHONY: process-manager
process-manager:
	go build ./go/cmd/process-manager

.PHONY: pmctl
pmctl:
	go build ./go/cmd/pmctl
