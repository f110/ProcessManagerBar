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
    json_log: true
    watch: true
```

### Top-level fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `processes` | list | Yes | Managed process definitions |
| `max_log_lines` | int | No | Maximum number of log lines retained in memory per tab (default: `1000`) |

### Process fields

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `name` | string | Yes | Process identifier |
| `command` | string[] | Yes | Command and arguments to execute |
| `dir` | string | Yes | Working directory |
| `log_file` | string | No | Log file path |
| `json_log` | bool | No | Parse logs as JSON (default: `false`) |
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
    json_log: true
    watch: true

  - name: worker
    command: ["python", "worker.py"]
    dir: /Users/me/project/worker
    log_file: ~/logs/worker.log
```
