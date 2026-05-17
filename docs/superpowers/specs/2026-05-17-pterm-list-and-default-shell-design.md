# `:PTermList` + default-shell — design spec

**Status:** draft, awaiting user review
**Date:** 2026-05-17
**Builds on:** `2026-05-17-persistent-term-nvim-design.md`

## 1. Purpose

Two small convenience additions:

1. `:PTerm <name>` (no `-- cmd`) launches the user's default shell instead of erroring.
2. `:PTermList` enumerates every persistent-term pane on the tmux server, with enough information for the user to decide what to attach to.

A third change — exposing `require("persistent_term").list()` as a public Lua API — is the foundation for both `:PTermList` and for user-built fuzzy-finder pickers (telescope/snacks/fzf-lua). The plugin itself does not ship a picker.

## 2. Scope

### In scope

- New argv form `:PTerm <name>` resolving to a default-shell argv.
- New command `:PTermList`.
- New public function `require("persistent_term").list()`.
- Extension of `tmux list-panes` format to include `#{pane_dead}`.
- One README "Recipes" subsection documenting a telescope integration.
- Unit and integration tests for all of the above.

### Out of scope

- Any built-in picker (floating window, keymaps, highlight groups).
- Per-pane metadata beyond `name`, `pane_id`, `window_id`, attached state, and live/dead status.
- Detecting attachment by *other* Neovim instances. `attached` is local-process-scoped.

## 3. `:PTerm` argv grammar

| Form | Behavior |
|---|---|
| `:PTerm dev` | Run the resolved default shell. |
| `:PTerm dev -- cmd args` | Run `cmd args` (unchanged). |
| `:PTerm dev --` | Error `empty command after --` (unchanged — catches typos). |
| `:PTerm dev cmd` | Error `invalid name "dev cmd"` (unchanged — missing `--`). |

### 3.1 Parser change (`command.parse_open_args`)

If the raw argument contains no ` -- ` separator and does not end with ` --`, the entire trimmed input is treated as the name. The returned `argv` field is populated by the shell resolver (§3.2). All existing validation paths are unchanged.

Detection order in the existing function:

1. If raw ends with `%s%-%-$` → existing "empty command after --" path.
2. Else if raw contains `%s%-%-%s` → existing name-then-argv path.
3. Else (new) → name-only path. Validate the trimmed input the same way the existing path validates the name half: split via `split_tokens`, require exactly one resulting token, require the trimmed raw string to equal that token (rejects names containing quote characters), require ≤64 chars, require `NAME_PATTERN` match. On success return `{ name = name, argv = nil }` and let `cmd_open` substitute the resolved shell argv.

`argv = nil` is the explicit signal to `cmd_open` that the caller wants a shell. The existing "empty after --" path returns `nil, err` (it is not a successful return), so there is no ambiguity between the two.

### 3.2 Shell resolution (`command.resolve_shell`)

```
1. shell = vim.env.SHELL
2. if shell and vim.fn.executable(shell) == 1 then return shell end
3. if vim.fn.executable("/bin/sh") == 1 then return "/bin/sh" end
4. error "no usable shell: $SHELL=<val-or-empty>, /bin/sh missing"
```

Called from `cmd_open` immediately after `parse_open_args` succeeds with `argv == nil`. Result is wrapped as `{ shell }` — a single-element argv — and assigned to `parsed.argv` before the existing flow continues. This keeps the shell-resolution side effect (and its potential error) on the synchronous command path so the user sees the error immediately via `log.error`, before any tmux call.

`$SHELL` is treated as a literal executable path, not as a quoted command line. Values like `/bin/bash` or `/usr/bin/fish` work; values like `/bin/bash -l` are not supported (and are not valid POSIX `$SHELL` content anyway — login-shell behavior is signaled by `argv[0]` starting with `-`, which is the shell's own concern, not ours).

## 4. `tmux list-panes` format extension

Current format: `'#{pane_id}\t#{window_id}\t#{@pterm_name}'` (3 tab-separated fields).
New format: `'#{pane_id}\t#{window_id}\t#{@pterm_name}\t#{pane_dead}'` (4 fields).

`pane_dead` is `1` if the process running in the pane has exited (and `remain-on-exit on` is holding the pane open), `0` otherwise.

### 4.1 Parser change (`tmux.parse_list_panes`)

Each row in the returned table gains a `dead` boolean field. Existing fields (`pane_id`, `window_id`, `name`) are unchanged. The parser must tolerate the trailing field being missing (defensive, for forward-compat with older builds that may have cached the 3-field format) by defaulting `dead = false`.

### 4.2 Existing call sites

- `command.name_in_use` — unchanged; reads `row.name`.
- `command.find_pane` — unchanged; reads `row.pane_id` and `row.name`.
- `command.complete_attach` — unchanged; reads `row.name` and `row.pane_id`.

No existing site needs to consume `dead`; the new field is purely additive.

## 5. `require("persistent_term").list()` public API

```lua
--- @return { name: string, pane_id: string, window_id: string,
---           attached: boolean, status: "live"|"dead" }[]
function M.list() end
```

Behavior:

- Runs `tmux list-panes` once via the existing helpers.
- On a fresh tmux server with no sessions, returns `{}` (reuses `is_no_server` helper from `command.lua`; the helper will need to be relocated or duplicated — see §8).
- On any other tmux failure, returns `{}` and logs a warning. (Rationale: this is a query API; callers should not have to pcall it.)
- Skips rows with empty `name` (orphan tmux panes that were not created by pterm — shouldn't occur on our isolated `-L persistent-term` socket, but the guard is cheap and makes the API safe to call against a shared socket if a future user does so).
- Maps `dead` field to `status = dead and "dead" or "live"`.
- `attached` is computed by iterating `vim.api.nvim_list_bufs()` once and checking for a buffer whose name equals `pterm://<name>`. Detached buffers are renamed to `pterm://<name> [detached]` by `bridge.detach`, so they do **not** match — `attached = false` for them, which is the desired semantic ("I'd need to re-attach to interact").

Pure function with respect to its inputs (tmux state + nvim buffer list). No caching.

## 6. `:PTermList` command

### 6.1 Registration

`plugin/persistent_term.lua` adds:

```lua
vim.api.nvim_create_user_command("PTermList", function(_)
  require("persistent_term").cmd_list()
end, { desc = "List persistent-term panes on the tmux server" })
```

### 6.2 Implementation (`command.cmd_list`)

```
1. rows = require("persistent_term").list()
2. if #rows == 0 then vim.notify("no persistent terminals", INFO); return end
3. Build header row: { "NAME", "PANE", "ATTACHED", "STATUS" }
4. Build data rows: for each, { name, pane_id, attached and "yes" or "no", status }
5. Compute column widths (max over header + data per column)
6. Render each row as fields joined by "  " (two spaces) and padded to width
7. vim.notify(table.concat(lines, "\n"), INFO)
```

Output, on a typical 4-pane setup:

```
NAME   PANE  ATTACHED  STATUS
dev    %12   yes       live
logs   %18   no        live
build  %22   no        dead
```

A single `vim.notify` call so notification UIs (noice, mini.notify, fidget) render it as one message. No floating window, no keymaps, no highlights.

### 6.3 Public façade

`init.lua` gains:

```lua
function M.list()
  return require("persistent_term.command").list()
end

function M.cmd_list()
  require("persistent_term.command").cmd_list()
end
```

`M.list` is the documented Lua API; `M.cmd_list` exists only as the command dispatch target.

## 7. README "Recipes" section

A new top-level subsection added to the README, sibling to whatever installation/usage sections already exist:

````markdown
## Recipes

### Telescope picker for `:PTermList`

```lua
vim.keymap.set("n", "<leader>tp", function()
  local pickers      = require("telescope.pickers")
  local finders      = require("telescope.finders")
  local conf         = require("telescope.config").values
  local actions      = require("telescope.actions")
  local action_state = require("telescope.actions.state")

  pickers.new({}, {
    prompt_title = "persistent-term",
    finder = finders.new_table {
      results = require("persistent_term").list(),
      entry_maker = function(row)
        return {
          value   = row.pane_id,
          display = string.format("%-12s  %s  %s",
                      row.name, row.status,
                      row.attached and "[attached]" or ""),
          ordinal = row.name,
        }
      end,
    },
    sorter = conf.generic_sorter({}),
    attach_mappings = function(_, map)
      actions.select_default:replace(function(bufnr)
        actions.close(bufnr)
        local entry = action_state.get_selected_entry()
        vim.cmd("PTermAttach " .. entry.value)
      end)
      return true
    end,
  }):find()
end, { desc = "Pick a persistent-term pane" })
```
````

Pure documentation. No telescope dependency added to the plugin.

## 8. Code organization

`is_no_server` currently lives as a file-local function in `command.lua`. Once `list()` needs it too, the cleanest move is to extract it to `tmux.lua` as `M.is_no_server(res)` so both modules can call it without duplicating logic. This is a 4-line move, no behavior change.

## 9. Errors and edge cases

- **`$SHELL` set to a path that no longer exists**: caught by `executable()` check, falls back to `/bin/sh`. No error visible to the user.
- **`$SHELL` unset AND `/bin/sh` missing**: extremely rare (broken system) but possible in minimal containers. Surfaces an error message before any tmux call.
- **`:PTermList` on a tmux server with no sessions**: returns `no persistent terminals`, not an error.
- **`:PTermList` while a pane is mid-detach** (race between detach renaming the buffer and `list()` walking buffers): worst case the row shows `attached = no` while the buffer still says `pterm://<name>` for a few milliseconds, or vice-versa. Visible inconsistency is a missed `yes`/`no` flip in a single render; harmless and self-correcting on the next `:PTermList`.
- **Two pterm buffers with the same `name` in the same nvim** (only possible if a user `:bwipeout`s a buffer without going through `:PTermKill`, then runs `:PTermAttach <name>` again): both buffers match the same row; `attached` is still `true`. Acceptable — the row is still actionable.

## 10. Tests

### 10.1 Unit (Lua, no tmux)

- `resolve_shell`:
  - SHELL set and executable → returns SHELL.
  - SHELL set, non-executable → returns `/bin/sh`.
  - SHELL unset → returns `/bin/sh`.
  - SHELL unset, /bin/sh missing → errors with the expected message. (Mock `vim.fn.executable`.)

- `parse_open_args`:
  - `"dev"` → `{ name = "dev", argv = nil }`.
  - `"dev -- bash -c 'echo hi'"` → existing behavior (unchanged).
  - `"dev --"` → error "empty command after --".
  - `"dev cmd"` → error "invalid name" (the bare two-token form has always been invalid; this test pins that the new shell-default path does not regress it).
  - `"my-shell"` → `{ name = "my-shell", argv = nil }` (hyphen in name still valid).

- `parse_list_panes`:
  - Row with trailing `\t0` → `dead = false`.
  - Row with trailing `\t1` → `dead = true`.
  - Row with no trailing field (3 tabs) → `dead = false` (back-compat default).

### 10.2 Integration (real tmux + real Go helper)

- `:PTerm dev` (no `--`) opens a buffer attached to a pane running the resolved shell. Test driver feeds `echo READY-$$\n` to the pane through the same mechanism existing integration tests use to inject keystrokes (the handle's `on_input` indirection) and then `vim.wait`s for a `READY-<digits>` line to appear in the captured pane content. Pins that the resolved shell is actually exec'd and responding.
- `:PTermList` against a freshly-killed tmux server prints `no persistent terminals`.
- `:PTermList` after opening 2 panes prints 3 lines (header + 2), with names matching, and `ATTACHED=yes` for both.
- After `:PTermKill` on one, `:PTermList` shows 1 row.
- After attaching, sending `exit\n` to a pane, waiting briefly, and re-running `:PTermList`: that row's `STATUS` flips to `dead`. (Relies on `remain-on-exit on` which is already set in `cmd_open`.)

## 11. Non-goals (revisited)

This spec deliberately does **not**:

- Add a `setup()` function or a config table for the default shell (no policy knob — `$SHELL` is universal).
- Add a `:PTermSelect` picker command (telescope recipe in README is the supported path).
- Track attachment by other nvim instances (would require a lockfile or shared state we don't want to maintain in v1).
- Surface tmux client state, window names, session names, or any other tmux metadata in `:PTermList`. The four columns are the actionable minimum.
