# tmux control-mode (`-CC`) redesign — design spec

**Status:** draft, awaiting user review
**Date:** 2026-05-18
**Supersedes (partially):** `2026-05-17-term-rendering-fix-design.md` §4.2 — the inline bootstrap block in `cmd_open` is replaced by the gateway's startup sequence. The xterm-256color / truecolor decisions themselves are preserved.
**Reference implementation:** iTerm2's `TmuxGateway` / `TmuxController` / `VT100TmuxParser`.

## 1. Purpose

After the previous fix landed `TERM=xterm-256color` and `COLORTERM=truecolor`, the rendering of basic text inside `:PTerm` panes is correct, but zsh's line-editing and zsh-autosuggestions remain visibly broken: prompt redraw leaves stale fragments, autosuggestions overlap typed characters. `bash` and simple TUIs are fine. The same zsh configuration renders correctly in Neovim's built-in `:terminal`, so libvterm itself is not the problem.

The root cause is the `tmux pipe-pane`-based bridge. When zsh issues terminal queries (DSR/CPR `\e[6n`, DA1 `\e[c`), **both** tmux and libvterm answer:

- tmux is the authoritative terminal for the child's pty — it responds to the query by writing the response onto the pty master, which the child reads as stdin.
- pipe-pane forwards the query bytes downstream to our Go helper → Unix socket → `nvim_open_term`'s libvterm.
- libvterm processes the query and auto-responds via the `on_input` callback.
- Our bridge writes that response back through the socket → pipe-pane stdin → tmux → child's pty stdin.

zsh consumes both responses. The second arrives late and is interpreted as a key sequence by zle, garbling the redraw. bash/readline doesn't query like this, which is why the previous integration tests passed.

The fix is structural: replace pipe-pane with tmux's control mode (`-CC`). In control mode, tmux is the sole terminal for the child; libvterm becomes render-only. iTerm2 has used this approach since 2011 and is the open-source reference.

## 2. Scope

### In scope
- New `lua/persistent_term/gateway.lua` — owns one long-lived `tmux -CC` subprocess per Neovim session, parses the line-oriented control-mode protocol, dispatches `%output` to per-pane subscribers, sends commands.
- New `lua/persistent_term/codec.lua` — pure functions: `decode_output_payload`, `encode_send_keys`, `is_libvterm_response`, `shell_escape`.
- Rewrite `lua/persistent_term/bridge.lua` — drops Unix socket / AUTH handshake; `on_input` callback feeds bytes through the codec + filter into `gateway.send_keys`.
- Rewrite `lua/persistent_term/command.lua` — `cmd_open` / `cmd_attach` / `cmd_kill` / `cmd_list` operate via the gateway.
- Shrink `lua/persistent_term/tmux.lua` to version utilities + a few parse helpers.
- Delete the entire `go/` directory and `lua/persistent_term/install.lua`. No `:PTermInstall` command.
- New + rewritten tests; same Plenary-busted framework.

### Out of scope
- Pause mode (`refresh-client -fpause-after`, `%pause`/`%continue`, `%extended-output`). Local-only use case; flow control unnecessary.
- Recovery mode (mid-stream reattach after Neovim restart). Each Neovim launch starts fresh; previous tmux state is rediscovered via `list-windows`.
- `refresh-client -B` subscriptions, server-side state stash (`@iterm2_size` analogues).
- Multiple panes per window. Each `:PTerm` continues to create one window with one pane.
- User-configurable TERM / COLORTERM. Hardcoded `xterm-256color` + `truecolor` from the previous spec.
- Bumping the minimum tmux version. Stays at 3.0, with `send-keys -H` and per-window `refresh-client -C @wid:…` gated on 3.0a / 3.4.

## 3. Architecture

**Singleton gateway, per-pane subscribers.** One `tmux -CC` subprocess for the whole Neovim instance. It owns the protocol parser and a `pane_id → callback` table. Each PTerm buffer registers a callback when its window is opened; bytes from `%output %<wp> …` are dispatched to the matching callback, which calls `vim.api.nvim_chan_send` on its libvterm channel.

Why singleton:
- Matches iTerm2's design.
- Halves per-pane fixed cost (no per-pane process / socket / parser).
- Single source of truth for pane lifecycle — `%window-close` events come on the gateway's stream and we know immediately which buffer to mark `[detached]`.
- VimLeave teardown is one `detach` command, not N.

**Lua-only, no Go helper.** The control-mode protocol is line-oriented text plus a 3-digit octal-escape decoder for `%output` payloads. Roughly a few hundred lines of Lua, well within what's testable in Plenary. Removing the Go binary eliminates: install command, helper-binary download/build, Unix socket + AUTH handshake, install spec, cross-compile platform considerations.

**Gateway state machine.**
- `stopped` — no tmux -CC process. First `:PTerm` call transitions to `starting`.
- `starting` — spawned the subprocess; waiting for the spontaneous `%begin … %end` block.
- `ready_no_session` — got the initial response; not yet authorized to write commands (no `%session-changed` yet).
- `ready` — accept user-issued commands. Normal state.
- `detaching` — `detach` command sent, waiting for `%exit`.
- `stopped` — process exited, all subscribers notified.

**Per-pane buffer flow.**
1. User runs `:PTerm name -- argv...`.
2. `gateway.send_cmd("new-window -d -P -F '#{pane_id}\t#{window_id}' -- " .. shell_escape(argv), cb)` — response body has one tab-separated line `%<wp>\t@<wid>`.
3. Register `cb := function(bytes) chan_send(chan, bytes) end` under pane id `%<wp>`.
4. `vim.cmd.buffer(bufnr)` displays the libvterm buffer. Initial `refresh-client -C @<wid>:<W>x<H>` sizes the pane to match.
5. zsh's `\e[6n` query: tmux answers `\e[r;cR` to zsh's stdin (single response, no second one); the query bytes also appear in `%output` and reach libvterm; libvterm sends a response through `on_input`; we filter it out in `codec.is_libvterm_response` before it would be sent as keystrokes.
6. User typing: `on_input` bytes that aren't auto-responses → `codec.encode_send_keys` → one batched `send-keys` command per encoding class → `gateway.send_cmd` → tmux.

**Filter is a backstop.** The primary correctness mechanism is the architecture: keystrokes go through `send-keys`, not through a pty input fd. Libvterm responses that we forward as `send-keys` would still create the double-response bug, so we drop CSI-with-final-byte-∈-{R,c,n} sequences in `codec`.

## 4. Protocol surface

### 4.1 Outbound (us → tmux stdin)

Plain text command lines terminated by `\n`. Helpers in `gateway.lua`:

| Helper | Sends | Used for |
|---|---|---|
| `start_attach()` | argv `{ "tmux", "-L", "persistent-term", "-CC", "new-session", "-A", "-s", "pterm", "-x", "80", "-y", "24" }` | Subprocess. `-A` = attach if `pterm` session exists, create if not. `-x/-y` are throwaway. |
| `gw.send_cmd("new-window …", cb)` | `new-window -d -P -F '#{pane_id}\t#{window_id}' -- argv...\n` | Create per-`:PTerm` window. |
| `gw.send_cmd("refresh-client -C …", cb)` | `refresh-client -C @<wid>:<cols>x<rows>\n` (≥3.4) or `resize-window -t @<wid> -x <cols> -y <rows>\n` (3.0–3.3) | Resize a specific window. |
| `gw.send_cmd("kill-window -t @<wid>", cb)` | `kill-window -t @<wid>\n` | `:PTermKill`. |
| `gw.send_cmd("list-windows …", cb)` | `list-windows -t pterm -F '#{window_id}\t#{pane_id}\t#{@pterm_name}\t#{pane_dead}'\n` | Rebuild `:PTermList`; replaces today's `list-panes -a`. |
| `gw.send_cmd("set-option -wt @<wid> @pterm_name <name>", cb)` | … | Tag a window with our name. |
| `gw.send_keys(pane_id, bytes)` | one or more of `send-keys -lt %<wp> …` / `send-keys -t %<wp> 0xNN …` / `send-keys -H -t %<wp> NN …` | Translated user input. Run-length-encoded by encoding class per iTerm2's `sendCodePoints`. |
| `gw.detach()` | `detach\n` | VimLeave / explicit shutdown. |

Every `send_cmd` enqueues `{ command, callback, want_data }`. Callbacks fire on the matching `%end` (success, body returned) or `%error` (failure, stderr in body).

### 4.2 Inbound (tmux stdout → us)

Line-oriented. Each line is one of:

| Line | Handling |
|---|---|
| `%begin <id> <num> [flags]` | Open a response block. Server-originated (`flags & 1 == 0`) ignored for v1. |
| arbitrary lines until `%end`/`%error` | Accumulate into the current response body. |
| `%end <id> <num>` | Fire head-of-queue callback with the body. |
| `%error <id> <num>` | Fire callback with `{ ok = false, stderr = body }`. |
| `%output %<wp> <octal-escaped-bytes>` | Decode payload, dispatch to subscriber. Hot path. |
| `%session-changed $<sid> <name>` | Promote `ready_no_session` → `ready`. After that, ignored. |
| `%window-add @<wid>` | Logged at debug; sanity-check for `new-window` responses. |
| `%window-close @<wid>` | Look up subscribers under that window; mark each buffer `[detached]`. |
| `%window-renamed @<wid> <name>` | Ignored (we own the rename via `@pterm_name`). |
| `%exit [reason]` | Flush pending callbacks with error, detach all buffers, transition to `stopped`. |
| anything else | Log at warn, do not abort. |

### 4.3 `%output` decoder

Per iTerm2's `decodeEscapedOutput` (TmuxGateway.m:147-177):
- Bytes `< 0x20`: skip (tmux's line-buffering chrome).
- `\` introduces exactly three octal digits (`\033` = ESC, `\134` = literal backslash).
- Anything else passes through literally; UTF-8 continuation bytes (`≥ 0x80`) survive.
- No `\\` form — only octal triples. A literal backslash arrives as `\134`.

### 4.4 `send-keys` encoder

Per iTerm2's `encodingForCodePoint` (TmuxGateway.m:1031-1048):
- Bucket A — `[A-Za-z0-9+/):,_]`: `send-keys -lt %<wp> <literal string, shell-escaped>`.
- Bucket B — other non-control: `send-keys -t %<wp> 0xNN 0xNN ...` (UTF-8 encoded for ≥ 0x80 via tmux's encoder).
- Bucket C — `0x00..0x1F` on tmux ≥ 3.0a: `send-keys -H -t %<wp> NN NN ...` (literal byte, bypasses tmux 3.5+'s `modifyOtherKeys` rewriting of C0 routed through Bucket B).

Run-length-encode by bucket; emit one command per run. Tmux 3.0 exactly (no `-H`) gets Bucket C bytes via Bucket B as a documented limitation.

### 4.5 Auto-response filter

Before encoding, scan `on_input` data for libvterm auto-responses and drop them. The filter recognizes CSI sequences (`\e[` … final-byte) whose parameter section contains only `[0-9;?>]` and whose final byte is `R`, `c`, or `n`:
- `\e[<digits>;<digits>R` — CPR (cursor position report).
- `\e[?<digits>(;<digits>)*c` — DA1 response.
- `\e[><digits>;<digits>(;<digits>)?c` — DA2 response.
- `\e[<digits>n` — DSR variants (e.g. `\e[0n` status OK, `\e[3n` malfunction).

User-typed CSI sequences (arrows `\e[A`, function keys `\e[15~`, modified keys `\e[1;5A`) end in letters or `~` and never in `R`/`c`/`n`. Safe.

## 5. Lifecycle

### 5.1 Start (lazy, on first `:PTerm`)
1. `gateway.ensure_started()` checks state. If `stopped`, spawn and transition to `starting`.
2. stdin/stdout are pipes; stderr is teed into `log.warn`.
3. The on-exit handler transitions to `stopped` and notifies subscribers.
4. tmux's spontaneous `%begin <t> 0 0` / `%end <t> 0 0` triggers `ready_no_session`. If `%error` instead, abort with the message.
5. tmux emits `%session-changed $<sid> pterm` → transition to `ready`.

### 5.2 Bootstrap commands

Sent as one batch immediately after entering `ready`. A single failure short-circuits the rest.
- `display-message -p "#{version}"` — caches version on the gateway. Replaces today's standalone `tmux -V` call.
- `set-option -g default-terminal xterm-256color`.
- `set-option -g terminal-features xterm-256color:RGB` (gated on `version_at_least(v, "3.2")`).
- `set-environment -g COLORTERM truecolor`.
- `list-windows -t pterm -F '#{window_id}\t#{pane_id}\t#{@pterm_name}\t#{pane_dead}'` — rebuilds the in-memory pane map (essential if tmux server already had panes from a prior Neovim).

The empty-server bootstrap headache from the previous spec is gone: `tmux -CC new-session -A -s pterm` always brings the server up first, so `set-option -g` runs against a live server every time.

### 5.3 Pane create

1. Validate name, resolve shell if argv omitted.
2. `gateway.ensure_started()` — if `ready`, returns synchronously. If `starting`, awaits via `vim.wait` on the state transition.
3. Lookup duplicate by name (in-memory map; rebuilt at bootstrap).
4. `bridge.create_buffer(name)` — creates the libvterm buffer + channel; registers `on_input` (encoder + filter → `gateway.send_keys`).
5. `gateway.send_cmd("new-window -d -P -F '#{pane_id}\t#{window_id}' -- " .. shell_escape(argv), cb)`.
6. On response: parse `%<wp>\t@<wid>`; store on the handle; subscribe `gateway.subscribers[pane_id] = function(bytes) chan_send(chan, bytes) end`; send `set-option -wt @<wid> @pterm_name <name>`; `set-option -wt @<wid> remain-on-exit on`; `refresh-client -C @<wid>:<W>x<H>`.
7. `vim.cmd.buffer(bufnr)` displays the buffer.

### 5.4 Pane death
- Server-side: `%window-close @<wid>` arrives on the gateway stream.
- Gateway looks up subscribers under that window (tracked via `wid → [pane_id, ...]`), invokes a `_on_close` hook that renames the buffer to `pterm://<name> [detached]` and stops accepting keystrokes.
- `:PTermKill`: `gateway.send_cmd("kill-window -t @<wid>", cb)`. tmux replies and emits `%window-close`; same dispatch path closes the buffer.

### 5.5 Server detach (VimLeave / `:PTermDetach`)
- `gateway.detach()` writes `detach\n`.
- tmux flushes pending `%end` / `%output`, writes `%exit`, closes stdout.
- We flush pending callbacks with `"control mode exiting"`, mark each subscribed buffer `[detached]`, transition to `stopped`.
- The tmux server **stays running** with the `pterm` session intact. Next Neovim launch's first `:PTerm` re-attaches.

### 5.6 Crash recovery
If the tmux -CC process exits unexpectedly (uv `on_exit` with nonzero code while `ready`):
- All in-flight callbacks fail with `"control mode died: <stderr-tail>"`.
- All subscribed buffers marked `[detached]`.
- State → `stopped`. Next `:PTerm` cleanly respawns.

### 5.7 Attach — `:PTermAttach <name|pane_id>`
1. `gateway.ensure_started()`.
2. Look up target in the in-memory map; refresh via `list-windows` if not found.
3. `bridge.create_buffer(name)`.
4. `gateway.send_cmd("capture-pane -p -e -J -t %<wp>", cb)` with `want_data=true` — replays scrollback as raw bytes.
5. Feed captured bytes into the channel via `chan_send`.
6. Subscribe the buffer under the pane id.

## 6. Sizing
- Gateway start: `refresh-client -C <vim.o.columns>,<vim.o.lines - 2>`. Authoritative session size (we're the only client).
- Per-pane initial: `refresh-client -C @<wid>:<W>x<H>` on ≥3.4, else `resize-window -t @<wid> -x <W> -y <H>`. `W`/`H` from `nvim_win_get_width/get_height` of the window where the buffer will be displayed.
- WinResized / VimResized autocmd (kept from current code): same `refresh-client -C @<wid>:<W>x<H>` (or `resize-window`). 50 ms debounce stays.
- Editor-wide resize: also bump the client size in the same batch.

## 7. Error handling
- **Subprocess fails to start**: `cmd_open` returns `nil, "tmux -CC could not start: <stderr>"`.
- **No `%begin` within 2 s of spawn**: handshake timeout. Kill subprocess, `stopped`, fail `cmd_open` with `"tmux -CC startup timeout"`.
- **`%error` on a user command**: callback gets `{ ok = false, stderr = body }`; `cmd_open` notifies and rolls back buffer/subscriber state.
- **`%error` on a bootstrap command**: fatal. Gateway transitions to `stopped`, all subscribers notified, message names the failed command.
- **Unexpected subprocess exit in `ready`**: per §5.6. Next `:PTerm` respawns.
- **`%output` for an unknown pane id**: log at debug, drop. (Pane closed simultaneously with last bytes.)
- **Unrecognized line on the stream**: log at warn, do not abort. iTerm2 aborts; we're more lenient because aborting kills every pterm in the editor and a debug log is more useful for diagnosing tmux version drift.
- **Stdin write fails**: treat as `%exit` arriving. Same teardown path.

## 8. Version gates

Single floor stays at 3.0.

| Feature | Min version | Fallback on older |
|---|---|---|
| `tmux -CC` | 2.1+ | None needed — already covered by existing `check_version("3.0")`. |
| `default-terminal` / `set-environment -g` | 3.0 | n/a. |
| `terminal-features` | 3.2 | Skip. |
| `send-keys -H` (literal byte for C0) | 3.0a | Encoder falls back to `send-keys 0xNN`. Documented limitation: modifier+letter combos may misrender on tmux 3.0 exactly. |
| `refresh-client -C @wid:WxH` (per-window) | 3.4 | `resize-window -t @wid -x W -y H`. |
| `%extended-output` / pause mode | 3.2 | We don't enable `pause-after`; tmux never emits these. |
| `refresh-client -B` subscriptions | 3.2 | We don't subscribe. |

Version captured once at bootstrap via `display-message -p "#{version}"`; cached on the gateway for its lifetime.

## 9. Cross-platform

### Linux
- `tmux -CC` available since tmux 2.1; all supported distros have ≥ 3.0. No change.
- `xterm-256color` terminfo in `ncurses-base` everywhere.

### macOS
- Bundled `/usr/bin/tmux` may be < 3.0 (already rejected by existing version gate). Homebrew (≥ 3.5) and MacPorts (≥ 3.4) work.
- `xterm-256color` ships system terminfo since 10.7.

### Containers / minimal systems
- `xterm-256color` terminfo entry needed inside the container. Same constraint as today; unchanged.

## 10. File structure delta

```
lua/persistent_term/
├── gateway.lua      NEW   subprocess + protocol parser + state machine
├── codec.lua        NEW   decode_output, encode_send_keys, is_libvterm_response, shell_escape
├── bridge.lua       SHRUNK  create_buffer, attach(handle, gateway, pane_id), resize_to, install_buffer_hook
├── command.lua      MODIFIED  cmd_open/attach/kill/list/cmd_list rewritten to talk to gateway
├── tmux.lua         SHRUNK  version_at_least, parse_list_panes, check_version
├── log.lua          UNCHANGED
└── init.lua         UNCHANGED public surface

plugin/persistent_term.lua  MODIFIED  removes :PTermInstall

go/                                  DELETED entire directory
lua/persistent_term/install.lua      DELETED
```

Net delta: roughly +500 lines Lua (gateway+codec), −300 lines Lua (bridge/tmux/install), −400 lines Go.

## 11. Tests

### 11.1 Codec unit tests — `tests/spec/codec_spec.lua` (new)
- Table-driven: every octal-escape edge case for `decode_output_payload` (literal backslash, ESC, NUL, high bytes, mid-stream `\r` skip, malformed `\` without three digits → `?` fallback).
- Encoder bucket boundaries for `encode_send_keys`: pure-printable run, pure-hex run, pure-literal-byte run, transitions, max-length splits at 1000-char boundary.
- `is_libvterm_response`: every CPR / DA1 / DA2 / DSR pattern, near-misses (arrow keys, function keys, modified keys) must NOT match.
- `shell_escape`: spaces, quotes, backslashes, multibyte chars.

### 11.2 Gateway unit tests — `tests/spec/gateway_spec.lua` (new)
- `gateway.lua` takes a `transport` parameter (default: real `vim.system`). Tests inject a fake transport with `write(bytes)` capture and a `feed(bytes)` to simulate tmux stdout.
- State transitions: `stopped → starting → ready_no_session → ready` on the canonical `%begin/%end + %session-changed` sequence; abort paths on `%error` and on timeout.
- Command queue: out-of-order responses, `%error` mid-batch, callback ordering.
- `%output` dispatch: subscriber lookup, drop for unknown pane id, payload decoding via codec.
- `%window-close` dispatch: subscriber `_on_close` fired; subsequent `%output` for that pane id dropped.
- `detach()` flow: writes `detach\n`, transitions to `detaching`, `%exit` triggers `stopped`.

### 11.3 Command unit tests — `tests/spec/command_spec.lua` (rewritten)
- `parse_open_args` tests preserved verbatim (no IPC dependency).
- `cmd_*` rewritten against a fake-gateway harness exposing `send_cmd`, `send_keys`, `subscribe`, `ensure_started`. Asserts the correct command argv was sent, the correct subscriber registered, error rollback works.

### 11.4 Integration tests — `tests/spec/integration_spec.lua` (extended)
- 14 existing tests preserved (their assertions don't depend on IPC mechanism).
- New tests:
  - **Single-response invariant**: a small script that writes `\e[6n` and reads exactly one `\e[<r>;<c>R` back, asserts no second response arrives within 200 ms. Direct verification that the double-response bug is gone.
  - **`:PTermKill` triggers `%window-close`**: assert that after `:PTermKill`, the buffer is renamed to `[detached]` within 500 ms and no subsequent `chan_send` calls happen for that pane id.
  - **Server persistence across detach**: open `:PTerm a`, detach the gateway, re-trigger gateway start, verify `list-windows` rediscovers the existing pane.

### 11.5 Deleted tests
- `tests/spec/bridge_spec.lua` (5 tests, AUTH handshake / socket I/O) → entire file.
- `tests/spec/install_spec.lua` (7 tests) → entire file.
- `tests/spec/tmux_spec.lua` (19 tests) — drop most argv-builder tests; keep `version_at_least`, `check_version`, `parse_list_panes`, `parse_new_session_output`. Net ~5 retained.

### 11.6 Test count budget

Before: 87 tests. After: ~120 tests (32 new codec + ~20 new gateway − 5 bridge − 7 install − 14 tmux argv-builder + 3 new integration).

## 12. Migration

Single-PR cutover. No flag, no parallel code paths — solo user has consented.

Order within the PR:
1. `codec.lua` + tests.
2. `gateway.lua` + tests.
3. Rewrite `bridge.lua`.
4. Rewrite `command.lua` + tests.
5. Delete `install.lua` + `go/`.
6. Update `plugin/persistent_term.lua` (drop `:PTermInstall`).
7. Update README and any user-facing docs.

Spec for the prior xterm-256color/COLORTERM fix is preserved as historical record; this spec supersedes its §4.2 (bootstrap is part of the gateway's startup sequence, not a separate inline block in `cmd_open`).

No data migration. tmux server state (windows, panes, `@pterm_name` user-options) survives. First `:PTerm` after upgrade re-attaches via `tmux -CC new-session -A -s pterm` and rediscovers panes through `list-windows`.

## 13. Risks
- Lua-side parser correctness is load-bearing on the keystroke path. Test coverage of `is_libvterm_response` and the encoder must be thorough.
- `send-keys` encoding has version-dependent behavior we'll only fully exercise via integration tests on the user's tmux installation.
- Deleting the Go helper means no easy rollback if a serious bug surfaces post-merge. Accepted: solo user, single PR, full test suite gate.

## 14. Reference

- iTerm2 source at `/tmp/iterm2-research/iTerm2/sources/` (research clone). Load-bearing files:
  - `tmux/TmuxGateway.h` + `.m` — protocol parser + command sender.
  - `VT100/VT100TmuxParser.m` — line-level DCS hook (not directly applicable to us since we spawn `tmux -CC` directly, but documents the recovery-mode logic for future reference).
  - `tmux/TmuxController.m` — higher-level controller; the bootstrap command list at `openWindowsOfSize:` was the basis for §5.2.
- tmux man pages: `tmux(1)`, especially the `CONTROL MODE` section. The on-the-wire grammar is informally specified there.
- Research notes for this spec generated by an `Explore` subagent against the iTerm2 clone; key findings are summarized inline.
