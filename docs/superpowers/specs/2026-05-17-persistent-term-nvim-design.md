# persistent-term.nvim — v1 design spec

**Status:** draft, awaiting user review
**Date:** 2026-05-17
**Supersedes:** `DESIGN.md` (kept as historical sketch; differs substantially from this spec)

## 1. Purpose

A Neovim plugin that exposes a hidden tmux pane as a Neovim terminal-mode buffer, so the process keeps running when Neovim dies and can be reattached after restart.

One job. No pickers, no statusline, no project roots, no auto-restore, no rename, no respawn, no policy knobs, no `setup()`.

## 2. Scope

### In scope (v1)

- Three user commands: `:PTerm`, `:PTermAttach`, `:PTermKill`, plus `:PTermInstall` for one-time binary fetch.
- Raw bidirectional byte proxy between Neovim and a hidden tmux pane.
- Scrollback replay on attach.
- Resize forwarding.
- Crash-resilience via tmux's durable PTY.
- Single Go helper binary, distributed prebuilt via GitHub Releases.
- Production-grade testing (Go unit + integration; Lua headless integration against real tmux) and CI (Linux + macOS × Neovim 0.10/stable/nightly).

### Out of scope (deferred indefinitely unless a concrete need appears)

- Project-root detection, project-local config, multi-project bookkeeping.
- Picker integration, statusline integration, auto-restore on `VimEnter`.
- Rename, respawn, readonly attach, attach policies, steal flags.
- A `setup()` function and any user-facing configuration table.
- Full-screen TUI fidelity beyond what `tmux capture-pane -e` provides.
- Multi-client writable attach to the same pane.

## 3. Architecture

Three processes:

```
+-------------------------------------+
| Neovim                              |
|   buffer (nvim_open_term)           |
|     - chan_send  : pane -> buffer   |
|     - on_input   : buffer -> pane   |
|   vim.uv Unix-socket server  -------+----+
+-------------------------------------+    |
                                           v
                        +------------------------------------+
                        | persistent-term-pipe (Go binary)   |
                        |   stdin  = tmux pane output stream |
                        |   stdout = tmux pane input stream  |
                        |   socket <-> raw bytes both ways   |
                        +-----------------+------------------+
                                          |
                                          | child of tmux server via:
                                          |   tmux pipe-pane -IO ...
                                          v
                        +------------------------------------+
                        | tmux pane (PTY, the real process)  |
                        +------------------------------------+
```

Invariants:

- Neovim is the socket **server**. The helper is the **client**.
- The helper does no interpretation; it shuffles bytes.
- Tmux runs on a dedicated socket `tmux -L persistent-term`, isolated from the user's normal tmux server and config.
- Pane is created with `remain-on-exit on`; finished commands stay visible until `:PTermKill`.
- Resize control is a separate channel: Lua runs `tmux resize-pane` directly, not via the bridge.

## 4. User surface

### 4.1 Commands

```
:PTerm {name} -- {cmd...}        Create a pane, open a buffer, attach the bridge.
:PTermAttach {name|pane_id}      Open a buffer for an already-running pane.
:PTermKill                       Kill the current buffer's pane and wipe the buffer.
:PTermInstall                    Download the helper binary into stdpath('data').
```

### 4.2 `:PTerm`

- Refuses if `--` is missing or `{cmd...}` is empty.
- `{name}` matches `^[A-Za-z0-9_.-]{1,64}$`. Otherwise: error, no state change.
- argv is everything after `--`; passed to tmux via `vim.system(argv)`. No shell.
- If a pane already exists with `@pterm_name == {name}` on the private tmux server: error `terminal "<name>" already exists (pane <pane_id>)`, no state change.
- On any failure between socket setup and bridge handshake: roll back (kill the pane if created, close the socket, wipe the buffer), emit `vim.notify` ERROR naming the failing step.

### 4.3 `:PTermAttach`

- Argument is either a name (matched against `@pterm_name` on known panes) or a raw pane id (`^%[0-9]+$`).
- Unknown name or pane id: error, no state change.
- If a `pterm://{name}` buffer is already attached: focus it, no new bridge.
- On attach: capture-pane -> chan_send to buffer -> start pipe -> live.
- Last attach wins: tmux replaces any prior pipe silently. Any other Neovim attached to the same pane sees its socket EOF, marks itself detached.

### 4.4 `:PTermKill`

- Must run from a `pterm://` buffer; else error.
- Closes the bridge, runs `tmux kill-pane`, wipes the buffer.

### 4.5 `:PTermInstall`

- Downloads `persistent-term-pipe-<os>-<arch>` and `.sha256` from GitHub Releases at the plugin's pinned version tag.
- Verifies SHA256 (refuses to install on mismatch).
- Writes to `stdpath('data') .. '/persistent-term/bin/persistent-term-pipe'`, mode `0755`.
- Idempotent: skip download if a matching binary already exists at the expected path with the expected hash.

### 4.6 Tab completion

- `:PTermAttach <Tab>`: union of all `@pterm_name` values plus all `%N` ids from `tmux -L persistent-term list-panes -aF '#{pane_id} #{@pterm_name}'`. Deduped, alphabetized.
- `:PTerm <Tab>`: no completion (name is being created).
- `:PTermKill <Tab>`: no completion (operates on current buffer).
- `:PTermInstall <Tab>`: no completion.

### 4.7 Buffer behavior

- Buffer options: `buftype=terminal`, `bufhidden=hide`, `swapfile=false`.
- Buffer name: `pterm://{name}`. When the bridge is not live, the name is suffixed `[detached]`: `pterm://dev [detached]`.
- Buffer-local variables: `vim.b.persistent_term_name`, `vim.b.persistent_term_pane_id`, `vim.b.persistent_term_session_id`.
- `:bd` / `BufWipeout` closes the bridge; the pane keeps running. Recovery: `:PTermAttach {name}`.
- `:PTermKill` is the only path that destroys the pane.
- No auto `startinsert` in v1.

## 5. Data plane

### 5.1 Socket handshake

The only framed portion of the protocol.

```
helper -> server : "AUTH " + token_hex + "\n"   (max 64 bytes incl. newline)
server -> helper : "OK\n"      success; switch to raw mode both directions
                or "ERR <reason>\n"   server closes socket; helper exits non-zero
```

- Token is 32 random bytes (`vim.uv.random`) hex-encoded; valid only for this socket; in memory only.
- Comparison is constant-time on the Go side (`subtle.ConstantTimeCompare`).
- After `OK\n`, neither side ever sends another framed message. All bytes are pane data.

### 5.2 Raw byte transport

- Helper: two goroutines, one for each direction, each doing `io.Copy` between `os.Stdin`/`os.Stdout` and the socket. No `bufio` line buffering anywhere.
- Neovim: `vim.uv.read_start` on the socket; each chunk is forwarded via `vim.api.nvim_chan_send(chan, data)` byte-for-byte. `on_input` callback writes the user's keystrokes back to the socket via `vim.uv.write`.
- No CR/LF translation, no UTF-8 validation, no ANSI parsing on either side.

### 5.3 Backpressure

- Helper: blocking writes naturally pause the corresponding reader. Bounded 8KB stack buffers per direction (`io.CopyBuffer`).
- Neovim: pending writes through `vim.uv.write` are queued. If the queue exceeds 64KB, **input** keystrokes are dropped with a WARN log; **output** (pane -> buffer) is never dropped — Neovim's terminal channel handles its own flow.

### 5.4 Resize

- Triggers: `VimResized`, `WinResized` for windows displaying a `pterm://` buffer.
- Debounce: 50ms (collapses bursts during interactive `:resize`).
- Computation: smallest `(cols, rows)` across all windows currently displaying the buffer. (Tmux's own multi-client rule.)
- Command: `tmux -L persistent-term resize-pane -t {pane_id} -x {cols} -y {rows}`. Runs via `vim.system`, no shell.
- Resize failures (pane gone, tmux dead) are logged WARN; the bridge cleanup path is triggered as for any other tmux failure.

### 5.5 Shutdown paths

| Trigger                  | Effect                                                                                   |
|--------------------------|------------------------------------------------------------------------------------------|
| `:PTermKill`             | close socket -> helper exits -> `tmux kill-pane` -> `bwipeout`                           |
| `:bd` / `BufWipeout`     | close socket -> helper exits -> tmux pane keeps running with `remain-on-exit`            |
| Neovim crash             | kernel closes socket fd -> helper sees EOF, exits -> pane keeps running                  |
| Helper crash / socket EOF| Neovim cancels bridge, renames buffer `pterm://{name} [detached]`, WARN notify           |
| External `kill-pane`     | helper's stdin/stdout closes, helper exits, socket EOF, Neovim cancels bridge as above   |
| External `tmux kill-server` | next tmux call from Neovim fails; affected buffers marked detached; WARN notify       |

## 6. Persistence

There is no metadata file. Tmux's pane-level user options are the source of truth.

- On create: `tmux set-option -p -t {pane_id} @pterm_name {name}`. Set immediately after `new-session`, before opening the buffer or starting the bridge.
- On list / completion / resolve: `tmux list-panes -aF '#{pane_id} #{@pterm_name}'` (run on demand; no in-process cache beyond a single command invocation).
- On kill: tmux removes the option with the pane; no extra cleanup.

Consequences:

- No state file, no atomic writes, no lockfile, no stale-cleanup logic.
- Multiple Neovim instances share state via tmux automatically.
- If a user kills the tmux server externally, all `@pterm_name` values vanish with it; `:PTermAttach <Tab>` shows nothing. Correct behavior.

Hard requirement: tmux 3.0 or newer (when pane user options landed).

## 7. Lifecycle flows

### 7.1 `:PTerm dev -- npm run dev` (happy path)

```
1.  Validate name; validate "--" present; argv non-empty.
2.  Pre-flight: tmux available, helper binary present (else error).
3.  list-panes; reject duplicate @pterm_name.
4.  Pick socket path: $XDG_RUNTIME_DIR/persistent-term/<random-16-hex>.sock
    (fallback /tmp/persistent-term-$UID/ with mode 0700).
5.  Generate 256-bit auth token (hex).
6.  vim.uv.listen on socket; install accept callback.
7.  nvim_open_term on a new scratch buffer; install on_input; set buffer-local vars.
8.  tmux -L persistent-term new-session -d -s pterm_<rand> -P \
        -F '#{session_id}\t#{pane_id}' -x <cols> -y <rows> -- argv...
    Capture session_id, pane_id.
9.  tmux set-option -w -t {window_id} remain-on-exit on
    tmux set-option -p -t {pane_id} @pterm_name dev
10. tmux pipe-pane -t {pane_id} -IO \
        'persistent-term-pipe --socket /path --token HEX'
11. Wait for helper connect + AUTH + OK (timeout 2s). Failure -> rollback.
12. Bridge live. Return focused buffer.
```

### 7.2 `:PTermAttach dev`

```
1.  Resolve dev -> %12 via list-panes; unknown -> abort.
2.  If pterm://dev already attached, focus and return.
3.  Steps 4-7 from above (socket, token, listen, open_term).
4.  capture-pane -p -e -J -S - -E - -t %12 ; chan_send into buffer.
5.  pipe-pane -t %12 -IO 'persistent-term-pipe --socket /path --token HEX'.
6.  Bridge live.
```

There is a tiny window between capture-pane and pipe-pane where the pane may emit output not present in either snapshot or live stream. Documented best-effort; not fixed in v1.

### 7.3 `:PTermKill`

```
1.  From a pterm:// buffer; else error.
2.  Close socket -> helper exits via stdin EOF.
3.  tmux kill-pane -t {pane_id}.
4.  bwipeout buffer.
```

### 7.4 Neovim crash recovery

Buffer is gone, socket fd was closed by the kernel, helper exited, tmux pane kept running. On next Neovim launch the user runs `:PTermAttach <name>` (tab-completion shows the surviving panes). No work needed during shutdown — by design we have no shutdown hook.

## 8. Error handling

### 8.1 Pre-flight (once per session, cached)

| Check                                                                  | On failure                                  |
|------------------------------------------------------------------------|---------------------------------------------|
| `tmux -V` present and version >= 3.0                                   | ERROR notify, refuse all commands           |
| Helper binary at `stdpath('data')/persistent-term/bin/persistent-term-pipe` and executable | ERROR notify with `run :PTermInstall` |

Cache invalidates on `:PTermInstall` completion.

### 8.2 User errors

Every user error path: clear `vim.notify` message, no state change, no log noise beyond the user-visible notification.

- Missing `--`, empty argv, bad name regex, duplicate name.
- Unknown name/pane id for `:PTermAttach`.
- `:PTermKill` outside a `pterm://` buffer.

### 8.3 Runtime failures

| Class                       | Response                                                                                                  |
|-----------------------------|-----------------------------------------------------------------------------------------------------------|
| Helper crashes / socket EOF | Cancel bridge, rename buffer `[detached]`, WARN notify with `:PTermAttach {name}` hint.                   |
| Tmux command fails          | Cancel bridge, rename buffer `[detached]`, WARN notify with the tmux stderr line.                         |
| Socket write queue > 64KB   | Drop input chunk, WARN log (rate-limited to once per second per buffer).                                  |
| Helper auth timeout (>2s)   | Same as helper crash; additional ERROR log line including the socket path.                                |

### 8.4 Logging

- User-facing: `vim.notify` for ERROR and WARN.
- Debug log file: `stdpath('log') .. '/persistent-term.log'`, append-only.
  - ERROR and WARN are always written.
  - DEBUG-level logging is enabled when the environment variable `PERSISTENT_TERM_DEBUG=1` is set at Neovim launch. Checked once at plugin load; no runtime toggle.
  - Self-truncates when file exceeds 1MB (rotates to `.1` once, no further rotation).

## 9. Security

### 9.1 No shell — with one documented exception

Every external command in Lua uses `vim.system(argv_table)`. Every external command in Go uses `exec.Command(name, args...)`. No `os.execute`, no `vim.fn.system(string)`, no string concatenation into a command line.

The one unavoidable shell layer is `tmux pipe-pane`: tmux runs its `[shell-command]` argument through `/bin/sh -c`. We mitigate by guaranteeing that every byte of that string is from a constrained alphabet that needs no escaping:

- Socket path: `<safe-prefix>/<16 hex chars>.sock`, where `<safe-prefix>` is `$XDG_RUNTIME_DIR/persistent-term/` or `/tmp/persistent-term-<numeric uid>/`. All characters are `[A-Za-z0-9_/.-]`.
- Token: `[a-f0-9]{64}`.
- Binary path: resolved to an absolute path under `stdpath('data')/persistent-term/bin/`, which is `[A-Za-z0-9_/.-]`.

The helper invocation is wrapped in single quotes when passed to `pipe-pane`:

```
tmux ... pipe-pane -t %12 -IO 'persistent-term-pipe --socket /path/abc.sock --token DEADBEEF...'
```

Single-quote escaping is unnecessary because no input contains a `'`, but is included for defense in depth. If any input ever breaks the alphabet, the pipe-pane call is refused at the argv-build step.

### 9.2 Name sanitization

`^[A-Za-z0-9_.-]{1,64}$` for names. `^%[0-9]+$` for pane ids. Rejection happens before any tmux call.

### 9.3 Socket security

- Parent directory `$XDG_RUNTIME_DIR/persistent-term/` (fallback `/tmp/persistent-term-$UID/`), mode `0700`, created via `vim.uv.fs_mkdir` with explicit mode.
- Socket file: 16 random bytes hex-encoded, no extension. Removed on bridge teardown.
- One-shot 256-bit auth token, in-memory, passed via helper argv. The `0700` parent dir is the primary boundary; the token closes a same-user race where another local process could connect before the legitimate helper.

### 9.4 Tmux isolation

- All tmux invocations use `-L persistent-term`.
- We never read the user's `~/.tmux.conf` (the `-L` socket starts a fresh server; we do not pass `-f`).
- We set `status off` on the dedicated server and `remain-on-exit on` on the window we create.

### 9.5 Helper hardening

- No filesystem access except the socket path.
- No network.
- Refuses to start if `--socket` is not absolute and not under `/run/user/`, `/tmp/`, or `$XDG_RUNTIME_DIR`.
- Constant-time token comparison.

### 9.6 Binary install verification

- HTTPS download from the GitHub Release matching the plugin's pinned version tag.
- SHA256 verification against a `.sha256` file from the same release.
- No GPG signature verification in v1 (no signing infra). Documented gap.

## 10. Repo layout

```
persistent-term.nvim/
  lua/persistent_term/
    init.lua            -- public API surface (commands, version, install entrypoint)
    command.lua         -- :PTerm, :PTermAttach, :PTermKill, :PTermInstall
    bridge.lua          -- socket server, on_input, chan_send, bridge lifecycle
    tmux.lua            -- argv-only wrappers (new, list, kill, pipe, capture, resize, set-option)
    install.lua         -- :PTermInstall: download + sha256 verify + chmod
    log.lua             -- vim.notify, append-only debug log with size cap
  plugin/persistent_term.lua   -- command registrations (autoload init.lua on demand)
  go/
    go.mod
    main.go             -- argv parsing, socket connect, auth, kick off proxy
    proxy.go            -- bidirectional io.Copy with backpressure
    main_test.go
    proxy_test.go
  tests/
    minimal_init.lua    -- nvim --headless bootstrap (sets runtimepath, loads plenary)
    spec/
      command_spec.lua
      bridge_spec.lua
      tmux_spec.lua
      integration_spec.lua
  Makefile
  .github/workflows/
    ci.yml              -- lint + test matrix
    release.yml         -- tag-driven cross-compile + release upload
  README.md
```

## 11. Testing

### 11.1 Go tests (`go test ./...`)

- Argv parsing (valid, invalid, missing `--socket`, missing `--token`).
- Auth handshake: correct token, wrong token, truncated token, no token sent.
- Constant-time comparison.
- Bidirectional `io.CopyBuffer` round-trip including:
  - 1MB random blob each direction.
  - NUL bytes, ESC sequences, CSI cursor movement, mouse-report escapes.
  - Mid-stream EOF on either end terminates the other direction cleanly.
- Backpressure: slow socket reader does not cause unbounded memory growth in the helper.

### 11.2 Lua tests (busted via plenary, `nvim --headless -u tests/minimal_init.lua`)

Unit:

- Name regex (positive and negative cases).
- `:PTerm` argv parser: returns the exact argv table for representative inputs.
- Tmux command builders: assert exact argv tables (no string concatenation reaches the network of tmux calls).
- Resize debounce: rapid resizes coalesce to one `resize-pane` call.

Integration (require real tmux on PATH; CI installs it):

- `:PTerm dev -- bash -c 'printf hello; sleep 30'` — buffer contains `hello` within 500ms.
- `:PTermAttach dev` after `:bd` — buffer reappears with prior output (via capture-pane replay).
- `:PTermKill` — `tmux -L persistent-term list-panes` no longer lists the pane.
- Duplicate-name rejection: second `:PTerm dev -- ...` errors and does not create a pane.
- Resize: `:resize 24` followed by `tmux display-message -p '#{pane_height}'` returns `24` after the debounce window.
- Crash-resilience: spawn child Neovim, run `:PTerm dev -- bash -c 'sleep 60'`, `kill -9` the child, start a new Neovim, `:PTermAttach dev` succeeds and shows scrollback.
- Last-attach-wins: two Neovim instances attach the same pane in sequence; the first detaches cleanly.

The integration suite uses the real Go binary built into `go/bin/persistent-term-pipe`. No stubs for the protocol.

## 12. Build & distribution

### 12.1 Makefile targets

```
build       Compile go/bin/persistent-term-pipe via `go build ./go`.
test        Depends on `build`. Runs:
              go test ./go/...
              nvim --headless -u tests/minimal_init.lua \
                -c "PlenaryBustedDirectory tests/spec/ {minimal_init='tests/minimal_init.lua'}"
lint        luacheck lua/ tests/
            stylua --check lua/ tests/
            (cd go && go vet ./...)
            (cd go && gofmt -l . | (! grep .))   # fail if any file needs formatting
release     Cross-compile to dist/persistent-term-pipe-{linux,darwin}-{amd64,arm64}
            plus a .sha256 file for each.
clean       Remove go/bin/ and dist/.
```

### 12.2 CI matrix (`.github/workflows/ci.yml`)

- OS: `ubuntu-latest`, `macos-latest`.
- Neovim: `v0.10.0`, `stable`, `nightly` (`actions/cache` Neovim builds).
- Go: `1.22.x` (`actions/setup-go`).
- Steps: install tmux (apt/brew) -> `make lint` -> `make build` -> `make test`.

### 12.3 Release workflow (`.github/workflows/release.yml`)

- Trigger: tag `v*`.
- Cross-compile four targets via `GOOS`/`GOARCH`:
  - `linux/amd64`, `linux/arm64`, `darwin/amd64`, `darwin/arm64`.
- For each: `sha256sum > <binary>.sha256`.
- Upload all eight artifacts (4 binaries + 4 sha files) to the GitHub Release for the tag.

### 12.4 Plugin install path

- Recommended: `{ "user/persistent-term.nvim", build = ":PTermInstall" }` in `lazy.nvim`.
- `:PTermInstall` reads its pinned version tag from a Lua constant baked into the plugin source. This guarantees binary <-> Lua API alignment.
- Development workflow: `make build` writes `go/bin/persistent-term-pipe`; the plugin checks `stdpath('data')/persistent-term/bin/` and uses whatever's there, so symlinking `go/bin/persistent-term-pipe` into the data dir lets you iterate without re-running `:PTermInstall`.

## 13. Minimum supported versions

- Neovim 0.10 (for `vim.uv`, `nvim_open_term` with `on_input`, `vim.system`).
- tmux 3.0 (for pane user options `@key` and reliable `pipe-pane -IO`).
- Go 1.22 (build-time only; users do not need Go installed).
- Linux and macOS only. Windows is not supported (tmux does not run natively on Windows; WSL works because the WSL environment is Linux).

## 14. Open follow-ups (post-v1)

Listed so they are not forgotten, not because they block v1:

- Live-buffer-first replay (start pipe-pane, buffer output, then capture-pane, then dedupe-and-flush) to eliminate the capture/live gap.
- Optional `setup({})` for tweaking debug log level, runtime dir, socket name prefix.
- `:PTermList` command (currently subsumed by `:PTermAttach <Tab>`).
- GPG-signed release artifacts.
