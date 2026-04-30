# ProcessManagerBar

macOS menu bar application for managing local development processes.

## Configuration

Create a YAML configuration file (e.g., `process.yaml`) to define managed processes.

### Format

```yaml
max_log_lines: 1000
processes:
  - name: http
    command: ["go", "run", "./cmd/server"]
    dir: /path/to/project
    log_file: ~/logs/server.log
    watch: true
```

### Top-level fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `processes` | list | Yes | Managed process definitions |
| `max_log_lines` | int | No | Maximum number of log lines retained in memory per tab (default: `1000`) |
| `server` | string | No | gRPC endpoint for [server mode](#server-mode) (`tcp://host:port` or `unix:///path/to/sock`) |

### Process fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | Yes | Process identifier |
| `command` | string[] | Yes | Command and arguments to execute |
| `dir` | string | Yes | Working directory |
| `log_file` | string | No | Log file path |
| `watch` | bool | No | Auto-restart on file changes in `dir` (default: `false`) |

### Notes

- Leading `~` is expanded to the user's home directory in `dir`, `log_file`, and every `command` entry.
- `command` array supports `$DIR` variable, which is replaced with the `dir` value.
- When `watch` is enabled, changes in the working directory trigger a process restart. The following directories are ignored: `.git`, `node_modules`, `vendor`, `.build`, `__pycache__`, `.svn`, `.hg`.

### Example

```yaml
processes:
  - name: api-server
    command: ["bazel", "run", "//cmd/server", "--", "--config", "$DIR/debug.conf", "--log-encoding", "json"]
    dir: /Users/me/project
    watch: true

  - name: worker
    command: ["python", "worker.py"]
    dir: /Users/me/project/worker
    log_file: ~/logs/worker.log
```

## Server mode

In server mode, the `process-manager` daemon owns the processes and exposes a gRPC API. The menu bar app and the `pmctl` CLI act as clients. This is useful when you want processes to keep running independently of the menu bar app, or to control them from a terminal.

### Running the daemon

```sh
process-manager --conf process.yaml --listen tcp://127.0.0.1:9000
```

| Flag | Default | Description |
|------|---------|-------------|
| `--conf` | (required) | Path to the YAML configuration file |
| `--listen` | `tcp://127.0.0.1:9000` | Listen address (`tcp://host:port` or `unix:///path/to/sock`). When omitted, the `server` field in the config file is used if set. |

### Connecting from the menu bar app

Add a `server` field to the YAML loaded by the app. When set, the app connects to the daemon instead of spawning processes itself. The `processes` block can be omitted on the client side because the daemon owns the configuration.

```yaml
server: tcp://127.0.0.1:9000
```

`unix:///path/to/sock` is also accepted. Server mode in the menu bar app requires macOS 15.0 or later.

### pmctl

`pmctl` is a command-line client for the daemon.

```sh
pmctl status                 # list all processes
pmctl status <name>          # show one process
pmctl restart <name>         # restart a process
pmctl logs <name>            # print captured logs
pmctl logs <name> -f         # follow logs (tail -f)
pmctl logs                   # print process-manager's own log
pmctl reload                 # reload the configuration file
```

Use `--server <addr>` to point at a non-default endpoint (defaults to `tcp://127.0.0.1:9000`).

#### `reload`

Re-reads the configuration file the daemon was started with and reconciles it against the running set:

- **Unchanged** entries keep running.
- **Changed** entries (any field of the process config differs) are stopped; the new definition is registered in stopped state.
- **Added** entries are registered in stopped state.
- **Removed** entries are stopped and unregistered.

Top-level fields (`max_log_lines`, `server`) are not re-applied; only the `processes` list is reconciled.
