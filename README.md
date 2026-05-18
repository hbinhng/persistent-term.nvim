# persistent-term.nvim

A Neovim buffer connected to a hidden tmux pane. If Neovim crashes, the process keeps running. Reattach with `:PTermAttach`.

One job. No pickers, no statusline, no project roots, no auto-restore.

## Motivation

I daily-drive a remote workstation over SSH. My setup is too complicated for mosh — no jump host support, no sophisticated port forwarding. So when the network stutters, the SSH connection drops, Neovim is killed, and every process running inside a `:terminal` buffer dies with it. Builds, test runs, REPL sessions — gone, no way to recover. So I wrote this.

## Requirements

- Neovim **0.10** or newer
- tmux **3.0** or newer
- Linux or macOS (WSL works; native Windows does not — tmux is Unix-only)

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "hbinhng/persistent-term.nvim",
  cmd = { "PTerm", "PTermAttach", "PTermKill", "PTermList" },
}
```

## Use

```vim
:PTerm dev -- npm run dev          " create a pane and open a buffer attached to it
:PTerm dev                         " same, but run $SHELL (falls back to /bin/sh)
:PTermAttach dev                   " reopen a buffer for an existing pane (after restart, etc.)
:PTermAttach %12                   " same, but by raw tmux pane id
:PTermList                         " print every pterm pane on the tmux server
:PTermKill                         " kill the current buffer's pane
```

- `:bd` (or `BufWipeout`) detaches the bridge but keeps the pane running. Reattach with `:PTermAttach`.
- `:PTermKill` is the only command that destroys the pane.
- Tab-completion on `:PTermAttach` lists every known name and raw pane id.
- `:PTermList` columns: `NAME PANE ATTACHED STATUS`. `ATTACHED=yes` means this Neovim instance has a live buffer for the pane; `STATUS=dead` means the pane's process exited but tmux preserved the pane (`remain-on-exit on`).

## How it works

```
Neovim (Lua gateway) <-CC stdio-> tmux -L persistent-term -CC <-> tmux pterm session (windows = panes)
```

Each `:PTerm` is one window in a shared `pterm` session on a private tmux socket (`tmux -L persistent-term`), isolated from your normal tmux server and config. The plugin talks to tmux over control mode (`tmux -CC`), the same protocol iTerm2 uses for its tmux integration.

The tmux server keeps running after Neovim quits, so the next Neovim launch can `:PTermAttach <name>` and find the shell exactly where you left it. Pane names are stored as tmux window user options (`@pterm_name`), so there is no metadata file to corrupt or stale.

## Recipes

### Telescope picker

`require("persistent_term").list()` returns a table of pane rows. Wire it into your fuzzy finder of choice instead of bundling a picker into the plugin:

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

## Diagnostics

- All errors and warnings show via `vim.notify` and are appended to `stdpath('log')/persistent-term.log`.
- For verbose diagnostics, launch Neovim with `PERSISTENT_TERM_DEBUG=1`.

## Behavior

- Multiple Neovim instances connect to the same tmux server independently. Each can subscribe to the same pane and observe the same live output.
- `:PTermAttach` replays the pane's current screen via `capture-pane -p -e -J`; live updates resume from there. The replayed scrollback is the visible screen only, not tmux's full history buffer.
- Full-screen TUIs (`htop`, `lazygit`, nested `nvim`) are best-effort. Alternate-screen state may not survive reattach.
- Per-keystroke input roundtrips through `tmux send-keys`, so there is a small added latency compared to `:terminal`. For ordinary shell use it is not noticeable.

## Development

```bash
make deps      # clone plenary.nvim into .deps/
make test      # nvim --headless busted (requires tmux on PATH)
make lua-lint  # luacheck + stylua --check
make clean
```

## License

MIT
