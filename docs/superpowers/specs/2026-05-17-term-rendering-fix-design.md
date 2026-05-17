# TERM rendering fix for `:PTerm` panes — design spec

**Status:** draft, awaiting user review
**Date:** 2026-05-17
**Builds on:** `2026-05-17-persistent-term-nvim-design.md`, `2026-05-17-pterm-list-and-default-shell-design.md`

## 1. Purpose

Fix the rendering corruption that appears when a `:PTerm` pane runs an interactive shell (zsh in particular, but the bug also affects bash with rich prompts and any TUI that emits xterm-style escapes). Symptoms reported by the user: blank lines between completion-menu rows, fragmented prompts, prompt fragments left behind after redraws.

Root cause: the `tmux -L persistent-term` socket runs with tmux's default `default-terminal` (compile-time `screen` on most builds). The pane's child process inherits `TERM=screen` and emits the screen-flavored escape-sequence subset. `nvim_open_term` is libvterm — an xterm-class emulator — and interprets those screen sequences incorrectly.

The fix advertises an xterm terminal to the child and to tmux's own capability awareness, and surfaces truecolor so modern prompts and TUIs render at full fidelity.

## 2. Scope

### In scope

- Server-level bootstrap before each `new-session`: `default-terminal xterm-256color`, `terminal-features xterm-256color:RGB` (tmux ≥ 3.2 only), `set-environment -g COLORTERM truecolor`.
- Per-session env on each `new-session`: `-e TERM=xterm-256color -e COLORTERM=truecolor`.
- Three new tmux builder argv helpers and a small bootstrap step in `cmd_open`.
- Unit and integration tests for the bootstrap sequence, version gating, and the server's resulting state.

### Out of scope

- User-configurable TERM/COLORTERM values (hardcoded for v1; no `setup()` or env-var escape hatch).
- Changes to `bridge.lua`, the Go helper, the AUTH/socket protocol, or any byte-level wire format.
- `tmux-256color` as the TERM value, or any change requiring extra terminfo entries not already on Linux + macOS by default.
- Bumping the minimum tmux version (stays at 3.0; `terminal-features` is gated).
- Italics/strikethrough `terminal-overrides` workarounds. `xterm-256color` already advertises them on every system where the plugin currently works.
- Changes to `:PTermAttach`. Attaching joins a pane that is already running with whatever env it was started with; bootstrap cannot retroactively change that. Bootstrapping on attach has no effect on the attached pane and is omitted.
- Automated regression tests that compare libvterm's rendered grid against expected glyphs. Out as scope creep; the env/options assertions are sufficient evidence.

## 3. Values

Hardcoded for v1. No user knob.

| Setting | Value | Where applied |
|---|---|---|
| tmux server option `default-terminal` | `xterm-256color` | `set-option -g` on the `-L persistent-term` socket |
| tmux server option `terminal-features` | `xterm-256color:RGB` | `set-option -g`, **only when tmux ≥ 3.2** |
| tmux global environment `COLORTERM` | `truecolor` | `set-environment -g` |
| Per-session env `TERM` | `xterm-256color` | `-e TERM=xterm-256color` on `new-session` |
| Per-session env `COLORTERM` | `truecolor` | `-e COLORTERM=truecolor` on `new-session` |

Why both server-options and per-session `-e`:

- `default-terminal` controls what tmux re-emits to libvterm; `-e TERM=…` sets what the child sees and survives if a user/test harness later twiddles `default-terminal`.
- `set-environment -g COLORTERM` covers all sessions on the server; `-e COLORTERM=…` is per-session, atomic, and visible at the argv site.

Why `xterm-256color` and not `tmux-256color`:

- libvterm emulates xterm. The two-step pipeline (child → tmux → libvterm) is consistent when every step thinks "xterm."
- `xterm-256color` ships in system terminfo on every supported Linux distro and macOS ≥ 10.7. `tmux-256color` is missing from macOS system terminfo; choosing it would force users to install Homebrew ncurses.

## 4. Code changes

### 4.1 `lua/persistent_term/tmux.lua`

Two new builders:

```lua
function M.builders.set_server_option(key, value)
  local argv = copy(SOCKET)
  vim.list_extend(argv, { "set-option", "-g", key, value })
  return argv
end

function M.builders.set_server_env(key, value)
  local argv = copy(SOCKET)
  vim.list_extend(argv, { "set-environment", "-g", key, value })
  return argv
end
```

`M.builders.new_session` gains two extra argv entries between `-c opts.cwd` and `-P -F …`:

```lua
"-e", "TERM=xterm-256color",
"-e", "COLORTERM=truecolor",
```

Final `new_session` argv shape:

```
tmux -L persistent-term new-session -d
  -s <session_name>
  -x <cols> -y <rows>
  -c <cwd>
  -e TERM=xterm-256color
  -e COLORTERM=truecolor
  -P -F #{session_id}\t#{pane_id}\t#{window_id}
  -- <argv...>
```

### 4.2 `lua/persistent_term/command.lua`

In `cmd_open`, after the existing `install.is_installed()` check and before the `list-panes` call, run the bootstrap sequence:

```lua
-- Bootstrap server-wide TERM/capability options. Idempotent; we re-run on
-- every PTerm so we don't carry "is the server configured?" state.
local boot = tmux.run(tmux.builders.set_server_option("default-terminal", "xterm-256color"))
if not boot.ok then
  return nil, "tmux set-option default-terminal failed: " .. boot.stderr
end
if tmux.version_at_least(v.version, "3.2") then
  boot = tmux.run(tmux.builders.set_server_option("terminal-features", "xterm-256color:RGB"))
  if not boot.ok then
    return nil, "tmux set-option terminal-features failed: " .. boot.stderr
  end
end
boot = tmux.run(tmux.builders.set_server_env("COLORTERM", "truecolor"))
if not boot.ok then
  return nil, "tmux set-environment COLORTERM failed: " .. boot.stderr
end
```

This block sits between the existing `install.is_installed()` check and the existing `list_panes` call. `v.version` is already available from the `tmux.check_version("3.0")` return value (existing code in `tmux.lua` returns `{ ok = true, version = v }` on success).

`cmd_attach` is unchanged.

### 4.3 No other files modified beyond tests

`bridge.lua`, `install.lua`, `log.lua`, the Go helper, and `plugin/persistent_term.lua` are untouched.

## 5. Error handling

The three bootstrap commands are short and address the local tmux server we just version-checked. The only realistic failures are "tmux server crashed between version check and bootstrap" (essentially impossible window) or "value rejected by tmux" (impossible — values are hardcoded literals). Policy:

- Any failure aborts `cmd_open` immediately, before creating buffers, opening sockets, or calling `new-session`.
- The user sees the tmux stderr verbatim, prefixed with which bootstrap step failed: `tmux set-option default-terminal failed: …`.
- No partial-state cleanup needed: the bootstrap runs before any new resources are allocated.

If we instead logged and continued, the resulting pane would render incorrectly — the exact symptom we are fixing — with no error surface to the user. Fail-fast is the cleaner choice.

Version gating for `terminal-features` is in-process: `tmux.version_at_least(v.version, "3.2")` re-uses the version string already cached by `check_version`. No additional subprocess spawned.

## 6. Cross-platform notes

### Linux

- `xterm-256color` is in `ncurses-base` on every supported distro.
- tmux ≥ 3.2 (the `terminal-features` floor) is available on Ubuntu 22.04+, Debian 11+, Fedora 35+, Arch, current Alpine.
- tmux 3.0/3.1 still gets `default-terminal` + `COLORTERM` env; truecolor advertisement is slightly degraded (handled by `COLORTERM` only, not by tmux's internal capability table).

### macOS

- `xterm-256color` ships with the system since 10.7 (2011).
- Homebrew tmux (3.5 at time of writing) and MacPorts tmux (3.4+) support `terminal-features`.
- Apple's bundled `/usr/bin/tmux` may be 2.x on older releases — already rejected by the existing `check_version("3.0")` gate, so unaffected by this work.

### Containers / minimal systems

- A container without `xterm-256color` in its terminfo database starts the child with a TERM that has no matching terminfo entry. The child either falls back to dumb mode or fails with "unknown terminal type." Same failure mode as Neovim's own `:terminal`; accepted.

## 7. Tests

### 7.1 Unit tests — `tests/spec/tmux_spec.lua`

1. **`new_session builds correct argv`** — extend the existing exact-match assertion to include the new `-e TERM=xterm-256color -e COLORTERM=truecolor` flags between `-c` and `-P`.
2. **`set_server_option builds correct argv`** — new test: argv matches `tmux -L persistent-term set-option -g <key> <value>`.
3. **`set_server_env builds correct argv`** — new test: argv matches `tmux -L persistent-term set-environment -g <key> <value>`.

### 7.2 Unit tests — `tests/spec/command_spec.lua`

The existing argv-recording fake (`new_session = function(opts) recorded_argv = opts.argv; return { "true" } end`) is extended to also record bootstrap argvs. New tests:

4. **`cmd_open issues bootstrap before new-session (tmux 3.2)`** — mock `check_version` to return `{ ok = true, version = "3.2" }`. Assert the recorded sequence is: `set-option default-terminal` → `set-option terminal-features` → `set-environment COLORTERM` → `new-session`.
5. **`cmd_open skips terminal-features on tmux 3.0`** — mock `version = "3.0"`. Assert `set-option terminal-features` is NOT recorded; the other three commands are.
6. **`cmd_open aborts when bootstrap fails`** — fake `set-option default-terminal` returns `{ ok = false, stderr = "no server" }`. Assert `cmd_open` returns `nil, "tmux set-option default-terminal failed: no server"`. Assert no buffer created, no socket file, no `new-session` argv recorded.

### 7.3 Integration test — `tests/spec/integration_spec.lua`

7. **`PTerm configures the server with xterm-256color and truecolor`**:
   - `:PTerm tterm -- bash -c 'echo PTERM_TERM=$TERM; echo PTERM_COLORTERM=$COLORTERM; sleep 30'`
   - `wait_until` the buffer contains substring `PTERM_TERM=xterm-256color` (verifies TERM env reached the child).
   - `wait_until` the buffer contains substring `PTERM_COLORTERM=truecolor` (verifies COLORTERM env reached the child).
   - `tmux -L persistent-term show-options -gv default-terminal` → `xterm-256color`
   - `tmux -L persistent-term show-environment -g COLORTERM` → `COLORTERM=truecolor`

   Two echoes (one per line) so line-wrap at narrow terminal widths can't merge or truncate the assertion. `PTERM_` prefix avoids matching unrelated text that may appear in a future test run.

   On tmux ≥ 3.2, additionally verify:
   - `tmux -L persistent-term show-options -gv terminal-features` contains `xterm-256color:RGB`.

   The test reads `tmux.check_version("3.2")` (via `tmux.version_at_least` on the tmux installed in the test environment) to decide whether to run the `terminal-features` sub-assertion.

### 7.4 Regression coverage

The 5 existing integration tests use `bash -c` with simple commands (`echo`, `printf`, `sleep`). Bash treats `screen` vs `xterm-256color` interchangeably for these commands, so the change is invisible to them. The full suite must still pass unmodified.

### 7.5 Test count delta

Before: 89 tests (76 unit + 13 integration).
After: ~95 tests (~81 unit + ~14 integration).

## 8. Migration / rollout

Single PR. No data migration, no breaking change to any public command or API. Existing PTerm panes opened in earlier sessions are unaffected (the bootstrap targets the tmux server, which is per-Neovim-launch in practice — when a new Neovim opens its first PTerm, it re-bootstraps).

## 9. Open questions

None. All design decisions resolved during brainstorming:

- Scope: TERM rendering + truecolor + sane tmux defaults.
- Delivery: server-options + per-session `-e` (both).
- Values: hardcoded.
- Bootstrap timing: inline on every `new-session` (no caching).
- tmux version: keep min at 3.0; gate `terminal-features` on 3.2+.
