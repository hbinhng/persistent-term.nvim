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
  cmd = { "PTerm", "PTermAttach", "PTermKill", "PTermInstall" },
}
```

`:PTermInstall` downloads the prebuilt helper binary into `stdpath('data')/persistent-term/bin/`.

## Use

```vim
:PTerm dev -- npm run dev          " create a pane and open a buffer attached to it
:PTermAttach dev                   " reopen a buffer for an existing pane (after restart, etc.)
:PTermAttach %12                   " same, but by raw tmux pane id
:PTermKill                         " kill the current buffer's pane
```

- `:bd` (or `BufWipeout`) detaches the bridge but keeps the pane running. Reattach with `:PTermAttach`.
- `:PTermKill` is the only command that destroys the pane.
- Tab-completion on `:PTermAttach` lists every known name and raw pane id.

## How it works

```
Neovim (vim.uv socket server) <-> persistent-term-pipe (Go) <-> tmux pipe-pane <-> tmux pane (PTY)
```

Tmux runs on its own private socket (`tmux -L persistent-term`), isolated from your normal tmux server and config. Pane names are stored as tmux pane user options (`@pterm_name`), so there is no metadata file to corrupt or stale.

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
