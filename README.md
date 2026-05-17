# persistent-term.nvim

A Neovim buffer connected to a hidden tmux pane. If Neovim crashes, the process keeps running. Reattach with `:PTermAttach`.

One job. No pickers, no statusline, no project roots, no auto-restore.

## Requirements

- Neovim **0.10** or newer
- tmux **3.0** or newer
- Linux or macOS (WSL works; native Windows does not — tmux is Unix-only)

## Install

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "hbinhng/persistent-term.nvim",
  build = ":PTermInstall",
  cmd = { "PTerm", "PTermAttach", "PTermKill", "PTermInstall", "PTermList" },
}
```

`:PTermInstall` downloads the prebuilt helper binary into `stdpath('data')/persistent-term/bin/`.

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
Neovim (vim.uv socket server) <-> persistent-term-pipe (Go) <-> tmux pipe-pane <-> tmux pane (PTY)
```

Tmux runs on its own private socket (`tmux -L persistent-term`), isolated from your normal tmux server and config. Pane names are stored as tmux pane user options (`@pterm_name`), so there is no metadata file to corrupt or stale.

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

## Limitations

- One Neovim instance can be attached to a given pane at a time. A second `:PTermAttach` silently kicks the previous one off (tmux's `pipe-pane` allows one pipe per pane).
- There is a small window between `capture-pane` history replay and the start of the live pipe where output may be missed on reattach.
- Full-screen TUIs (`htop`, `lazygit`, nested `vim`) are best-effort; alternate-screen state may not survive reattach.

## Development

```bash
make deps      # clone plenary.nvim into .deps/
make build     # compile go/bin/persistent-term-pipe
make test      # go test + nvim --headless busted (requires tmux on PATH)
make lint      # luacheck + stylua --check + go vet + gofmt -l
make release   # cross-compile dist/ matrix + .sha256 files
make clean
```

When developing, `make build` writes the helper to `go/bin/persistent-term-pipe`. Symlink it into the data dir so `:PTermInstall` is not required:

```sh
mkdir -p ~/.local/share/nvim/persistent-term/bin
ln -sf "$(pwd)/go/bin/persistent-term-pipe" ~/.local/share/nvim/persistent-term/bin/persistent-term-pipe
```

## License

MIT
