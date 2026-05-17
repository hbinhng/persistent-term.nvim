# persistent-term.nvim Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship v1 of `persistent-term.nvim` exactly as specified in `docs/superpowers/specs/2026-05-17-persistent-term-nvim-design.md` — a hidden tmux pane exposed as a Neovim terminal buffer, surviving Neovim crashes, with production-grade tests and CI.

**Architecture:** Three processes — Neovim (Lua + `vim.uv` socket server + `nvim_open_term`), `persistent-term-pipe` (small Go binary that proxies raw bytes between its stdin/stdout and a Unix socket), tmux (durable PTY backend on a dedicated `-L persistent-term` socket). Bridge bytes are raw; resize is a separate control channel via `tmux resize-pane`. No metadata file — tmux pane user options (`@pterm_name`) are the source of truth.

**Tech Stack:** Lua 5.1 (Neovim 0.10+), Go 1.22, tmux 3.0+, busted (via plenary.nvim) for Lua tests, standard `go test` for Go tests, GitHub Actions for CI/release.

---

## File Structure

```
persistent-term.nvim/
├── lua/persistent_term/
│   ├── init.lua            # public API: open(), attach(), kill(), install()
│   ├── command.lua         # ex-command handlers + argv parsing + tab completion
│   ├── bridge.lua          # socket server, nvim_open_term wiring, lifecycle
│   ├── tmux.lua            # argv-only tmux command builders + executor + version check
│   ├── install.lua         # :PTermInstall download + SHA256 verify
│   └── log.lua             # vim.notify wrappers + debug file logger
├── plugin/persistent_term.lua   # ex-command registrations
├── go/
│   ├── go.mod
│   ├── main.go             # process entrypoint
│   ├── args.go             # argv parsing + safe-path guard
│   ├── handshake.go        # AUTH client-side
│   ├── proxy.go            # bidirectional io.CopyBuffer with backpressure
│   ├── args_test.go
│   ├── handshake_test.go
│   ├── proxy_test.go
│   └── main_test.go        # end-to-end via Unix socket
├── tests/
│   ├── minimal_init.lua    # nvim --headless bootstrap (sets runtimepath, loads plenary)
│   ├── setup.sh            # clones plenary into .deps/plenary.nvim
│   └── spec/
│       ├── command_spec.lua
│       ├── tmux_spec.lua
│       ├── bridge_spec.lua
│       └── integration_spec.lua    # requires real tmux
├── Makefile
├── .github/workflows/
│   ├── ci.yml              # lint + test matrix
│   └── release.yml         # tag-driven cross-compile + release upload
├── .gitignore
├── .luacheckrc
├── stylua.toml
└── README.md
```

**Boundaries:**
- `tmux.lua` exposes pure argv builders (testable without tmux) + a single executor wrapper around `vim.system`. Command-builder tests assert exact argv tables, not strings.
- `bridge.lua` is the only module that touches `vim.uv` and `nvim_open_term`. Tests use a real socket pair inside a headless Neovim — no mocking of libuv.
- `command.lua` orchestrates `bridge` + `tmux` + `install`; tests inject fakes via `package.loaded` swap.
- `install.lua` shells out to `curl` via `vim.system` (no Lua HTTP stack required).
- `log.lua` is a leaf module — no other module depends on a specific level being enabled.

---

## Task 1: Repo bootstrap

**Files:**
- Create: `.gitignore`
- Create: `.luacheckrc`
- Create: `stylua.toml`
- Create: `go/go.mod`
- Create: `Makefile`
- Create: `tests/setup.sh`
- Create: `tests/minimal_init.lua`

- [ ] **Step 1: Write `.gitignore`**

```gitignore
.deps/
go/bin/
dist/
*.log
.luarc.json
```

- [ ] **Step 2: Write `.luacheckrc`**

```lua
std = "luajit"
globals = { "vim" }
read_globals = { "describe", "it", "before_each", "after_each", "pending", "assert" }
exclude_files = { ".deps/" }
max_line_length = 120
```

- [ ] **Step 3: Write `stylua.toml`**

```toml
column_width = 120
line_endings = "Unix"
indent_type = "Spaces"
indent_width = 2
quote_style = "AutoPreferDouble"
call_parentheses = "Always"
```

- [ ] **Step 4: Write `go/go.mod`**

```go
module github.com/hbinhng/persistent-term.nvim/go

go 1.22
```

Run: `cd go && go mod tidy`
Expected: no errors, no dependencies added (we use stdlib only).

- [ ] **Step 5: Write `tests/setup.sh`**

```bash
#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPS="$ROOT/.deps"
mkdir -p "$DEPS"
if [ ! -d "$DEPS/plenary.nvim" ]; then
  git clone --depth 1 https://github.com/nvim-lua/plenary.nvim "$DEPS/plenary.nvim"
fi
```

Then: `chmod +x tests/setup.sh`

- [ ] **Step 6: Write `tests/minimal_init.lua`**

```lua
local root = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1).source:sub(2)), ":h:h")
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:prepend(root .. "/.deps/plenary.nvim")
vim.opt.swapfile = false
vim.cmd("runtime plugin/plenary.vim")
```

- [ ] **Step 7: Write skeleton `Makefile`**

```make
.PHONY: build test lint clean deps

deps:
	./tests/setup.sh

clean:
	rm -rf go/bin dist .deps

# Real targets are added in later tasks as code/tests land.
build:
	@echo "build: nothing to do yet (no Go sources)"

test:
	@echo "test: nothing to do yet"

lint:
	@echo "lint: nothing to do yet"
```

- [ ] **Step 8: Verify everything is wired**

Run: `make deps && ls .deps/plenary.nvim/lua/plenary/init.lua`
Expected: file exists.

Run: `make clean && ls .deps 2>/dev/null; echo done`
Expected: `done` (directory gone).

- [ ] **Step 9: Commit**

```bash
git add .gitignore .luacheckrc stylua.toml Makefile go/go.mod tests/setup.sh tests/minimal_init.lua
git commit -m "chore: bootstrap repo (linters, go.mod, plenary fetch, makefile skeleton)"
```

---

## Task 2: Go — argv parser

**Files:**
- Create: `go/args.go`
- Create: `go/args_test.go`

- [ ] **Step 1: Write the failing tests**

```go
// go/args_test.go
package main

import (
	"errors"
	"os"
	"testing"
)

func TestParseArgsHappyPath(t *testing.T) {
	t.Setenv("XDG_RUNTIME_DIR", "/run/user/1000")
	args, err := parseArgs([]string{
		"--socket", "/run/user/1000/persistent-term/abc.sock",
		"--token", "deadbeef",
	})
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if args.SocketPath != "/run/user/1000/persistent-term/abc.sock" {
		t.Errorf("SocketPath = %q", args.SocketPath)
	}
	if args.Token != "deadbeef" {
		t.Errorf("Token = %q", args.Token)
	}
}

func TestParseArgsMissingSocket(t *testing.T) {
	_, err := parseArgs([]string{"--token", "deadbeef"})
	if !errors.Is(err, errMissingSocket) {
		t.Errorf("err = %v, want errMissingSocket", err)
	}
}

func TestParseArgsMissingToken(t *testing.T) {
	_, err := parseArgs([]string{"--socket", "/tmp/foo.sock"})
	if !errors.Is(err, errMissingToken) {
		t.Errorf("err = %v, want errMissingToken", err)
	}
}

func TestParseArgsRelativeSocketPathRejected(t *testing.T) {
	_, err := parseArgs([]string{"--socket", "foo.sock", "--token", "x"})
	if !errors.Is(err, errUnsafeSocketPath) {
		t.Errorf("err = %v, want errUnsafeSocketPath", err)
	}
}

func TestParseArgsUnsafeAbsolutePathRejected(t *testing.T) {
	os.Unsetenv("XDG_RUNTIME_DIR")
	_, err := parseArgs([]string{"--socket", "/etc/passwd", "--token", "x"})
	if !errors.Is(err, errUnsafeSocketPath) {
		t.Errorf("err = %v, want errUnsafeSocketPath", err)
	}
}

func TestParseArgsTmpAllowed(t *testing.T) {
	os.Unsetenv("XDG_RUNTIME_DIR")
	_, err := parseArgs([]string{"--socket", "/tmp/persistent-term-1000/abc.sock", "--token", "x"})
	if err != nil {
		t.Errorf("unexpected error: %v", err)
	}
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd go && go test -run TestParseArgs -v`
Expected: FAIL with `undefined: parseArgs`.

- [ ] **Step 3: Implement `args.go`**

```go
// go/args.go
package main

import (
	"errors"
	"flag"
	"io"
	"os"
	"path/filepath"
	"strings"
)

var (
	errMissingSocket    = errors.New("--socket is required")
	errMissingToken     = errors.New("--token is required")
	errUnsafeSocketPath = errors.New("--socket must be absolute and under /run/user/, /tmp/, or $XDG_RUNTIME_DIR")
)

// Args holds the parsed command-line arguments.
type Args struct {
	SocketPath string
	Token      string
}

func parseArgs(argv []string) (Args, error) {
	fs := flag.NewFlagSet("persistent-term-pipe", flag.ContinueOnError)
	fs.SetOutput(io.Discard)
	var a Args
	fs.StringVar(&a.SocketPath, "socket", "", "Unix socket path")
	fs.StringVar(&a.Token, "token", "", "authentication token")
	if err := fs.Parse(argv); err != nil {
		return Args{}, err
	}
	if a.SocketPath == "" {
		return Args{}, errMissingSocket
	}
	if a.Token == "" {
		return Args{}, errMissingToken
	}
	if !filepath.IsAbs(a.SocketPath) || !isSafeSocketPath(a.SocketPath) {
		return Args{}, errUnsafeSocketPath
	}
	return a, nil
}

func isSafeSocketPath(p string) bool {
	safe := []string{"/run/user/", "/tmp/"}
	if xdg := os.Getenv("XDG_RUNTIME_DIR"); xdg != "" {
		safe = append(safe, strings.TrimRight(xdg, "/")+"/")
	}
	for _, prefix := range safe {
		if strings.HasPrefix(p, prefix) {
			return true
		}
	}
	return false
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd go && go test -run TestParseArgs -v`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add go/args.go go/args_test.go
git commit -m "feat(go): argv parser with safe-socket-path guard"
```

---

## Task 3: Go — AUTH handshake (client side)

**Files:**
- Create: `go/handshake.go`
- Create: `go/handshake_test.go`

- [ ] **Step 1: Write the failing tests**

```go
// go/handshake_test.go
package main

import (
	"bufio"
	"net"
	"strings"
	"testing"
	"time"
)

// helper: spawn a Unix socket server that accepts one connection and
// returns the connection along with the line it received.
func acceptOne(t *testing.T, sockPath string) (net.Conn, string) {
	t.Helper()
	ln, err := net.Listen("unix", sockPath)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { ln.Close() })
	conn, err := ln.Accept()
	if err != nil {
		t.Fatalf("accept: %v", err)
	}
	r := bufio.NewReader(conn)
	line, err := r.ReadString('\n')
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	return conn, line
}

func TestHandshakeSuccess(t *testing.T) {
	sockPath := tempSock(t)
	done := make(chan error, 1)
	go func() {
		conn, err := handshake(sockPath, "DEADBEEF", time.Second)
		if err != nil {
			done <- err
			return
		}
		conn.Close()
		done <- nil
	}()

	srvConn, line := acceptOne(t, sockPath)
	if line != "AUTH DEADBEEF\n" {
		t.Errorf("got line %q", line)
	}
	if _, err := srvConn.Write([]byte("OK\n")); err != nil {
		t.Fatalf("write: %v", err)
	}
	srvConn.Close()

	if err := <-done; err != nil {
		t.Errorf("handshake error: %v", err)
	}
}

func TestHandshakeRejection(t *testing.T) {
	sockPath := tempSock(t)
	done := make(chan error, 1)
	go func() {
		_, err := handshake(sockPath, "BADTOKEN", time.Second)
		done <- err
	}()

	srvConn, _ := acceptOne(t, sockPath)
	srvConn.Write([]byte("ERR auth\n"))
	srvConn.Close()

	err := <-done
	if err == nil || !strings.Contains(err.Error(), "auth") {
		t.Errorf("expected auth error, got %v", err)
	}
}

func TestHandshakeServerNeverReplies(t *testing.T) {
	sockPath := tempSock(t)
	done := make(chan error, 1)
	go func() {
		_, err := handshake(sockPath, "X", 200*time.Millisecond)
		done <- err
	}()

	srvConn, _ := acceptOne(t, sockPath)
	defer srvConn.Close()
	// Never write. Wait past the deadline.
	select {
	case err := <-done:
		if err == nil {
			t.Error("expected timeout error")
		}
	case <-time.After(2 * time.Second):
		t.Error("handshake did not return within timeout")
	}
}

func tempSock(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	return dir + "/test.sock"
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd go && go test -run TestHandshake -v`
Expected: FAIL with `undefined: handshake`.

- [ ] **Step 3: Implement `handshake.go`**

```go
// go/handshake.go
package main

import (
	"bufio"
	"errors"
	"fmt"
	"net"
	"strings"
	"time"
)

// handshake connects to sockPath, sends "AUTH <token>\n", and waits for
// "OK\n". Returns the live connection on success, or an error otherwise.
// The provided timeout bounds connect+write+read together.
func handshake(sockPath, token string, timeout time.Duration) (net.Conn, error) {
	deadline := time.Now().Add(timeout)
	d := net.Dialer{Timeout: timeout}
	conn, err := d.Dial("unix", sockPath)
	if err != nil {
		return nil, fmt.Errorf("dial %s: %w", sockPath, err)
	}
	if err := conn.SetDeadline(deadline); err != nil {
		conn.Close()
		return nil, err
	}
	if _, err := fmt.Fprintf(conn, "AUTH %s\n", token); err != nil {
		conn.Close()
		return nil, fmt.Errorf("write auth: %w", err)
	}
	r := bufio.NewReader(conn)
	line, err := r.ReadString('\n')
	if err != nil {
		conn.Close()
		return nil, fmt.Errorf("read auth reply: %w", err)
	}
	line = strings.TrimRight(line, "\n")
	if line == "OK" {
		// Clear the deadline now that we're in raw mode.
		if err := conn.SetDeadline(time.Time{}); err != nil {
			conn.Close()
			return nil, err
		}
		return conn, nil
	}
	conn.Close()
	if strings.HasPrefix(line, "ERR ") {
		return nil, errors.New("server rejected auth: " + strings.TrimPrefix(line, "ERR "))
	}
	return nil, errors.New("server sent unexpected reply: " + line)
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd go && go test -run TestHandshake -v`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add go/handshake.go go/handshake_test.go
git commit -m "feat(go): AUTH handshake client with bounded deadline"
```

---

## Task 4: Go — bidirectional proxy

**Files:**
- Create: `go/proxy.go`
- Create: `go/proxy_test.go`

- [ ] **Step 1: Write the failing tests**

```go
// go/proxy_test.go
package main

import (
	"bytes"
	"crypto/rand"
	"io"
	"net"
	"sync"
	"testing"
	"time"
)

// proxyHarness wires a fake socket and stdin/stdout streams together
// using net.Pipe and io.Pipe.
type proxyHarness struct {
	socket     net.Conn
	socketPeer net.Conn
	stdin      *io.PipeReader
	stdinWrite *io.PipeWriter
	stdout     *io.PipeReader
	stdoutW    *io.PipeWriter
}

func newProxyHarness() *proxyHarness {
	socket, peer := net.Pipe()
	stdinR, stdinW := io.Pipe()
	stdoutR, stdoutW := io.Pipe()
	return &proxyHarness{
		socket: socket, socketPeer: peer,
		stdin: stdinR, stdinWrite: stdinW,
		stdout: stdoutR, stdoutW: stdoutW,
	}
}

func TestProxyStdinToSocket(t *testing.T) {
	h := newProxyHarness()
	done := make(chan error, 1)
	go func() {
		done <- runProxy(h.socket, h.stdin, h.stdoutW)
	}()

	want := []byte("hello\x00world\x1b[31m")
	go func() {
		h.stdinWrite.Write(want)
		h.stdinWrite.Close()
	}()

	buf := make([]byte, len(want))
	if _, err := io.ReadFull(h.socketPeer, buf); err != nil {
		t.Fatalf("read socket: %v", err)
	}
	if !bytes.Equal(buf, want) {
		t.Errorf("socket got %q, want %q", buf, want)
	}

	h.socketPeer.Close()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("runProxy did not return")
	}
}

func TestProxySocketToStdout(t *testing.T) {
	h := newProxyHarness()
	done := make(chan error, 1)
	go func() {
		done <- runProxy(h.socket, h.stdin, h.stdoutW)
	}()

	want := []byte("\x1b[2J\x1b[Hready\n")
	go func() {
		h.socketPeer.Write(want)
		h.socketPeer.Close()
	}()

	buf := make([]byte, len(want))
	if _, err := io.ReadFull(h.stdout, buf); err != nil {
		t.Fatalf("read stdout: %v", err)
	}
	if !bytes.Equal(buf, want) {
		t.Errorf("stdout got %q, want %q", buf, want)
	}

	h.stdinWrite.Close()
	select {
	case <-done:
	case <-time.After(2 * time.Second):
		t.Fatal("runProxy did not return")
	}
}

func TestProxyOneMegabyteRoundTrip(t *testing.T) {
	h := newProxyHarness()
	done := make(chan error, 1)
	go func() { done <- runProxy(h.socket, h.stdin, h.stdoutW) }()

	const size = 1 << 20
	payload := make([]byte, size)
	if _, err := rand.Read(payload); err != nil {
		t.Fatal(err)
	}

	var wg sync.WaitGroup
	wg.Add(2)

	gotSocket := make([]byte, size)
	go func() {
		defer wg.Done()
		io.ReadFull(h.socketPeer, gotSocket)
	}()

	gotStdout := make([]byte, size)
	go func() {
		defer wg.Done()
		io.ReadFull(h.stdout, gotStdout)
	}()

	go func() { h.stdinWrite.Write(payload); h.stdinWrite.Close() }()
	go func() { h.socketPeer.Write(payload); h.socketPeer.Close() }()

	wg.Wait()
	if !bytes.Equal(gotSocket, payload) {
		t.Error("socket payload mismatch")
	}
	if !bytes.Equal(gotStdout, payload) {
		t.Error("stdout payload mismatch")
	}

	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("runProxy did not return")
	}
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd go && go test -run TestProxy -v`
Expected: FAIL with `undefined: runProxy`.

- [ ] **Step 3: Implement `proxy.go`**

```go
// go/proxy.go
package main

import (
	"io"
	"net"
	"sync"
)

const copyBufferSize = 8 * 1024

// runProxy copies bytes bidirectionally between the connection and the
// stdin/stdout streams until either direction ends. It returns when both
// goroutines have finished. The returned error is the first error seen
// (nil on clean EOF).
func runProxy(conn net.Conn, stdin io.Reader, stdout io.Writer) error {
	var (
		wg      sync.WaitGroup
		mu      sync.Mutex
		firstErr error
	)
	record := func(err error) {
		if err == nil || err == io.EOF {
			return
		}
		mu.Lock()
		if firstErr == nil {
			firstErr = err
		}
		mu.Unlock()
	}

	// stdin -> conn
	wg.Add(1)
	go func() {
		defer wg.Done()
		buf := make([]byte, copyBufferSize)
		_, err := io.CopyBuffer(conn, stdin, buf)
		record(err)
		// Half-close so the peer can drain. For net.Pipe / Unix sockets
		// closing the whole conn here would prematurely cut the other
		// direction; rely on the other goroutine to detect EOF.
		if uc, ok := conn.(interface{ CloseWrite() error }); ok {
			uc.CloseWrite()
		} else {
			conn.Close()
		}
	}()

	// conn -> stdout
	wg.Add(1)
	go func() {
		defer wg.Done()
		buf := make([]byte, copyBufferSize)
		_, err := io.CopyBuffer(stdout, conn, buf)
		record(err)
		// Closing stdout will unblock any pending writer on the other side.
		if cw, ok := stdout.(io.Closer); ok {
			cw.Close()
		}
	}()

	wg.Wait()
	return firstErr
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd go && go test -run TestProxy -v`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add go/proxy.go go/proxy_test.go
git commit -m "feat(go): bidirectional byte proxy with 8KB buffers"
```

---

## Task 5: Go — main.go wiring + end-to-end test

**Files:**
- Create: `go/main.go`
- Create: `go/main_test.go`

- [ ] **Step 1: Write the failing end-to-end test**

```go
// go/main_test.go
package main

import (
	"bufio"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"testing"
	"time"
)

// buildHelper compiles the binary into a temp dir and returns the path.
func buildHelper(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	out := filepath.Join(dir, "persistent-term-pipe")
	_, here, _, _ := runtime.Caller(0)
	pkgDir := filepath.Dir(here)
	cmd := exec.Command("go", "build", "-o", out, ".")
	cmd.Dir = pkgDir
	if b, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("go build failed: %v\n%s", err, b)
	}
	return out
}

func TestEndToEndHelper(t *testing.T) {
	binary := buildHelper(t)
	// Listen on a Unix socket under a safe prefix ($XDG_RUNTIME_DIR or /tmp).
	dir, err := os.MkdirTemp("/tmp", "persistent-term-test-*")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	sockPath := filepath.Join(dir, "e2e.sock")
	ln, err := net.Listen("unix", sockPath)
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()

	cmd := exec.Command(binary, "--socket", sockPath, "--token", "TOK")
	stdin, err := cmd.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer cmd.Process.Kill()

	conn, err := ln.Accept()
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()

	// Read AUTH line.
	r := bufio.NewReader(conn)
	line, err := r.ReadString('\n')
	if err != nil {
		t.Fatal(err)
	}
	if line != "AUTH TOK\n" {
		t.Fatalf("got %q", line)
	}
	conn.Write([]byte("OK\n"))

	// stdin -> socket
	if _, err := stdin.Write([]byte("ping\n")); err != nil {
		t.Fatal(err)
	}
	buf := make([]byte, 5)
	conn.SetReadDeadline(time.Now().Add(2 * time.Second))
	if _, err := r.Read(buf); err != nil {
		t.Fatal(err)
	}
	if string(buf) != "ping\n" {
		t.Errorf("socket got %q", buf)
	}

	// socket -> stdout
	conn.Write([]byte("pong\n"))
	stdoutBuf := make([]byte, 5)
	if _, err := stdout.Read(stdoutBuf); err != nil {
		t.Fatal(err)
	}
	if string(stdoutBuf) != "pong\n" {
		t.Errorf("stdout got %q", stdoutBuf)
	}

	// Closing the socket should make the helper exit cleanly.
	conn.Close()
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case err := <-done:
		if err != nil {
			t.Errorf("helper exited with error: %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("helper did not exit after socket close")
	}
}

func TestEndToEndRejectsBadAuth(t *testing.T) {
	binary := buildHelper(t)
	dir, err := os.MkdirTemp("/tmp", "persistent-term-test-*")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	sockPath := filepath.Join(dir, "auth.sock")
	ln, err := net.Listen("unix", sockPath)
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()

	cmd := exec.Command(binary, "--socket", sockPath, "--token", "GOOD")
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer cmd.Process.Kill()

	conn, err := ln.Accept()
	if err != nil {
		t.Fatal(err)
	}
	r := bufio.NewReader(conn)
	if _, err := r.ReadString('\n'); err != nil {
		t.Fatal(err)
	}
	conn.Write([]byte("ERR auth\n"))
	conn.Close()

	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	select {
	case err := <-done:
		if err == nil {
			t.Error("helper should exit non-zero on auth rejection")
		}
	case <-time.After(2 * time.Second):
		t.Fatal("helper did not exit after auth rejection")
	}
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd go && go test -run TestEndToEnd -v`
Expected: FAIL — `main.go` is missing.

- [ ] **Step 3: Implement `main.go`**

```go
// go/main.go
package main

import (
	"fmt"
	"os"
	"time"
)

const handshakeTimeout = 2 * time.Second

func main() {
	args, err := parseArgs(os.Args[1:])
	if err != nil {
		fmt.Fprintln(os.Stderr, "persistent-term-pipe:", err)
		os.Exit(2)
	}
	conn, err := handshake(args.SocketPath, args.Token, handshakeTimeout)
	if err != nil {
		fmt.Fprintln(os.Stderr, "persistent-term-pipe: handshake:", err)
		os.Exit(3)
	}
	defer conn.Close()
	if err := runProxy(conn, os.Stdin, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "persistent-term-pipe: proxy:", err)
		os.Exit(4)
	}
}
```

- [ ] **Step 4: Run all Go tests to verify they pass**

Run: `cd go && go test ./... -v`
Expected: PASS (all tests from Tasks 2, 3, 4, 5).

- [ ] **Step 5: Commit**

```bash
git add go/main.go go/main_test.go
git commit -m "feat(go): wire main entrypoint and add end-to-end test"
```

---

## Task 6: Makefile — Go build/test/lint targets

**Files:**
- Modify: `Makefile`

- [ ] **Step 1: Replace skeleton targets with real ones**

Read the current `Makefile`, then replace it with:

```make
.PHONY: build test lint clean deps go-build go-test go-lint

ROOT := $(shell pwd)
GO_BIN := $(ROOT)/go/bin/persistent-term-pipe

deps:
	./tests/setup.sh

clean:
	rm -rf go/bin dist .deps

go-build:
	mkdir -p go/bin
	cd go && go build -o bin/persistent-term-pipe .

go-test:
	cd go && go test ./...

go-lint:
	cd go && go vet ./...
	cd go && gofmt -l . | (! grep .)

build: go-build

test: go-build go-test

lint: go-lint
```

- [ ] **Step 2: Verify the targets work**

Run: `make build && file go/bin/persistent-term-pipe`
Expected: ends with `ELF 64-bit LSB executable` (Linux) or `Mach-O 64-bit executable` (macOS).

Run: `make test`
Expected: all Go tests pass.

Run: `make lint`
Expected: no output, exit 0.

Run: `make clean && ls go/bin 2>/dev/null; echo done`
Expected: `done`.

- [ ] **Step 3: Commit**

```bash
git add Makefile
git commit -m "build: real Makefile targets for go-build, go-test, go-lint"
```

---

## Task 7: Lua — `log.lua`

**Files:**
- Create: `lua/persistent_term/log.lua`
- Create: `tests/spec/log_spec.lua`

- [ ] **Step 1: Write the failing test**

```lua
-- tests/spec/log_spec.lua
describe("persistent_term.log", function()
  local log
  local tmp_log

  before_each(function()
    package.loaded["persistent_term.log"] = nil
    tmp_log = vim.fn.tempname()
    vim.env.PERSISTENT_TERM_LOG_PATH = tmp_log
    vim.env.PERSISTENT_TERM_DEBUG = nil
    log = require("persistent_term.log")
  end)

  after_each(function()
    vim.fn.delete(tmp_log)
    vim.env.PERSISTENT_TERM_LOG_PATH = nil
  end)

  it("writes ERROR lines to the log file", function()
    log.error("boom")
    local lines = vim.fn.readfile(tmp_log)
    assert.equals(1, #lines)
    assert.is_truthy(lines[1]:match("ERROR%s+boom"))
  end)

  it("writes WARN lines to the log file", function()
    log.warn("careful")
    local lines = vim.fn.readfile(tmp_log)
    assert.equals(1, #lines)
    assert.is_truthy(lines[1]:match("WARN%s+careful"))
  end)

  it("skips DEBUG when env is unset", function()
    log.debug("noisy")
    local ok, lines = pcall(vim.fn.readfile, tmp_log)
    if ok then
      assert.equals(0, #lines)
    end
  end)

  it("writes DEBUG when PERSISTENT_TERM_DEBUG=1", function()
    package.loaded["persistent_term.log"] = nil
    vim.env.PERSISTENT_TERM_DEBUG = "1"
    local log2 = require("persistent_term.log")
    log2.debug("noisy")
    local lines = vim.fn.readfile(tmp_log)
    assert.equals(1, #lines)
    assert.is_truthy(lines[1]:match("DEBUG%s+noisy"))
  end)

  it("rotates the file once when it exceeds 1MB", function()
    local big = string.rep("x", 1024 * 1024 + 10)
    vim.fn.writefile({ big }, tmp_log)
    log.error("after-rotate")
    assert.equals(1, vim.fn.filereadable(tmp_log .. ".1"))
    local lines = vim.fn.readfile(tmp_log)
    assert.equals(1, #lines)
    assert.is_truthy(lines[1]:match("ERROR%s+after-rotate"))
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `make deps && nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/spec/log_spec.lua {minimal_init='tests/minimal_init.lua'}"`
Expected: failure — module not found.

- [ ] **Step 3: Implement `log.lua`**

```lua
-- lua/persistent_term/log.lua
local M = {}

local debug_enabled = (vim.env.PERSISTENT_TERM_DEBUG == "1")

local function log_path()
  if vim.env.PERSISTENT_TERM_LOG_PATH and vim.env.PERSISTENT_TERM_LOG_PATH ~= "" then
    return vim.env.PERSISTENT_TERM_LOG_PATH
  end
  local dir = vim.fn.stdpath("log")
  vim.fn.mkdir(dir, "p")
  return dir .. "/persistent-term.log"
end

local function maybe_rotate(path)
  local size = vim.fn.getfsize(path)
  if size <= 0 or size <= 1024 * 1024 then
    return
  end
  os.rename(path, path .. ".1")
end

local function write(level, msg)
  local path = log_path()
  maybe_rotate(path)
  local line = string.format("%s %-5s %s\n", os.date("!%Y-%m-%dT%H:%M:%SZ"), level, msg)
  local fp = io.open(path, "a")
  if not fp then
    return
  end
  fp:write(line)
  fp:close()
end

function M.error(msg)
  write("ERROR", msg)
  vim.schedule(function()
    vim.notify("[persistent-term] " .. msg, vim.log.levels.ERROR)
  end)
end

function M.warn(msg)
  write("WARN", msg)
  vim.schedule(function()
    vim.notify("[persistent-term] " .. msg, vim.log.levels.WARN)
  end)
end

function M.debug(msg)
  if not debug_enabled then
    return
  end
  write("DEBUG", msg)
end

return M
```

- [ ] **Step 4: Run test to verify it passes**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/spec/log_spec.lua {minimal_init='tests/minimal_init.lua'}"`
Expected: 5 tests pass.

- [ ] **Step 5: Commit**

```bash
git add lua/persistent_term/log.lua tests/spec/log_spec.lua
git commit -m "feat(lua): log module with file logger and PERSISTENT_TERM_DEBUG env toggle"
```

---

## Task 8: Lua — `tmux.lua` command builders

**Files:**
- Create: `lua/persistent_term/tmux.lua`
- Create: `tests/spec/tmux_spec.lua`

- [ ] **Step 1: Write the failing tests for command builders**

```lua
-- tests/spec/tmux_spec.lua
describe("persistent_term.tmux builders", function()
  local tmux

  before_each(function()
    package.loaded["persistent_term.tmux"] = nil
    tmux = require("persistent_term.tmux")
  end)

  it("new_session builds correct argv", function()
    local argv = tmux.builders.new_session({
      session_name = "pterm_abc",
      cols = 120,
      rows = 32,
      cwd = "/home/u",
      argv = { "npm", "run", "dev" },
    })
    assert.same({
      "tmux", "-L", "persistent-term",
      "new-session", "-d",
      "-s", "pterm_abc",
      "-x", "120", "-y", "32",
      "-c", "/home/u",
      "-P", "-F", "#{session_id}\t#{pane_id}\t#{window_id}",
      "--", "npm", "run", "dev",
    }, argv)
  end)

  it("list_panes builds correct argv", function()
    assert.same({
      "tmux", "-L", "persistent-term",
      "list-panes", "-a",
      "-F", "#{pane_id} #{@pterm_name}",
    }, tmux.builders.list_panes())
  end)

  it("kill_pane builds correct argv", function()
    assert.same({
      "tmux", "-L", "persistent-term",
      "kill-pane", "-t", "%12",
    }, tmux.builders.kill_pane("%12"))
  end)

  it("pipe_pane builds shell-quoted helper invocation", function()
    local argv = tmux.builders.pipe_pane({
      pane_id = "%12",
      bin_path = "/home/u/.local/share/nvim/persistent-term/bin/persistent-term-pipe",
      socket_path = "/run/user/1000/persistent-term/abc.sock",
      token = "deadbeef",
    })
    assert.same({
      "tmux", "-L", "persistent-term",
      "pipe-pane", "-t", "%12", "-IO",
      "'/home/u/.local/share/nvim/persistent-term/bin/persistent-term-pipe'"
        .. " --socket '/run/user/1000/persistent-term/abc.sock'"
        .. " --token 'deadbeef'",
    }, argv)
  end)

  it("pipe_pane rejects unsafe characters in any field", function()
    assert.has_error(function()
      tmux.builders.pipe_pane({
        pane_id = "%12",
        bin_path = "/tmp/x'/persistent-term-pipe",
        socket_path = "/tmp/x.sock",
        token = "ABCD",
      })
    end)
    assert.has_error(function()
      tmux.builders.pipe_pane({
        pane_id = "%12",
        bin_path = "/tmp/bin",
        socket_path = "/tmp/x.sock",
        token = "ABCD; rm",
      })
    end)
  end)

  it("capture_pane builds correct argv", function()
    assert.same({
      "tmux", "-L", "persistent-term",
      "capture-pane", "-p", "-e", "-J",
      "-S", "-", "-E", "-",
      "-t", "%12",
    }, tmux.builders.capture_pane("%12"))
  end)

  it("resize_pane builds correct argv", function()
    assert.same({
      "tmux", "-L", "persistent-term",
      "resize-pane", "-t", "%12",
      "-x", "80", "-y", "24",
    }, tmux.builders.resize_pane("%12", 80, 24))
  end)

  it("set_pane_option builds correct argv", function()
    assert.same({
      "tmux", "-L", "persistent-term",
      "set-option", "-p", "-t", "%12",
      "@pterm_name", "dev",
    }, tmux.builders.set_pane_option("%12", "@pterm_name", "dev"))
  end)

  it("set_window_option builds correct argv", function()
    assert.same({
      "tmux", "-L", "persistent-term",
      "set-option", "-w", "-t", "@7",
      "remain-on-exit", "on",
    }, tmux.builders.set_window_option("@7", "remain-on-exit", "on"))
  end)

  it("version_check_argv builds correct argv", function()
    assert.same({ "tmux", "-V" }, tmux.builders.version_check())
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/spec/tmux_spec.lua {minimal_init='tests/minimal_init.lua'}"`
Expected: failure — module not found.

- [ ] **Step 3: Implement `tmux.lua` builders**

```lua
-- lua/persistent_term/tmux.lua
local M = {}

M.builders = {}

local SOCKET = { "tmux", "-L", "persistent-term" }
local SAFE_CHARS = "^[%w_%-%./@%%]+$"
local SAFE_TOKEN = "^[a-f0-9]+$"

local function copy(t)
  local r = {}
  for i, v in ipairs(t) do
    r[i] = v
  end
  return r
end

local function ensure_safe(field, value, pattern)
  if type(value) ~= "string" or value == "" or not value:match(pattern) then
    error(string.format("persistent_term.tmux: unsafe value for %s: %q", field, tostring(value)))
  end
end

function M.builders.new_session(opts)
  local argv = copy(SOCKET)
  vim.list_extend(argv, {
    "new-session", "-d",
    "-s", opts.session_name,
    "-x", tostring(opts.cols), "-y", tostring(opts.rows),
    "-c", opts.cwd,
    "-P", "-F", "#{session_id}\t#{pane_id}\t#{window_id}",
    "--",
  })
  vim.list_extend(argv, opts.argv)
  return argv
end

function M.builders.list_panes()
  local argv = copy(SOCKET)
  vim.list_extend(argv, { "list-panes", "-a", "-F", "#{pane_id} #{@pterm_name}" })
  return argv
end

function M.builders.kill_pane(pane_id)
  local argv = copy(SOCKET)
  vim.list_extend(argv, { "kill-pane", "-t", pane_id })
  return argv
end

function M.builders.pipe_pane(opts)
  ensure_safe("bin_path", opts.bin_path, SAFE_CHARS)
  ensure_safe("socket_path", opts.socket_path, SAFE_CHARS)
  ensure_safe("token", opts.token, SAFE_TOKEN)
  local helper = string.format(
    "'%s' --socket '%s' --token '%s'",
    opts.bin_path,
    opts.socket_path,
    opts.token
  )
  local argv = copy(SOCKET)
  vim.list_extend(argv, { "pipe-pane", "-t", opts.pane_id, "-IO", helper })
  return argv
end

function M.builders.capture_pane(pane_id)
  local argv = copy(SOCKET)
  vim.list_extend(argv, {
    "capture-pane", "-p", "-e", "-J",
    "-S", "-", "-E", "-",
    "-t", pane_id,
  })
  return argv
end

function M.builders.resize_pane(pane_id, cols, rows)
  local argv = copy(SOCKET)
  vim.list_extend(argv, {
    "resize-pane", "-t", pane_id,
    "-x", tostring(cols), "-y", tostring(rows),
  })
  return argv
end

function M.builders.set_pane_option(pane_id, key, value)
  local argv = copy(SOCKET)
  vim.list_extend(argv, { "set-option", "-p", "-t", pane_id, key, value })
  return argv
end

function M.builders.set_window_option(window_id, key, value)
  local argv = copy(SOCKET)
  vim.list_extend(argv, { "set-option", "-w", "-t", window_id, key, value })
  return argv
end

function M.builders.version_check()
  return { "tmux", "-V" }
end

return M
```

- [ ] **Step 4: Run test to verify it passes**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/spec/tmux_spec.lua {minimal_init='tests/minimal_init.lua'}"`
Expected: all builder tests pass.

- [ ] **Step 5: Commit**

```bash
git add lua/persistent_term/tmux.lua tests/spec/tmux_spec.lua
git commit -m "feat(lua): pure-function tmux argv builders with safety guards"
```

---

## Task 9: Lua — `tmux.lua` executor + version check + list parser

**Files:**
- Modify: `lua/persistent_term/tmux.lua`
- Modify: `tests/spec/tmux_spec.lua`

- [ ] **Step 1: Add the failing tests**

Append to `tests/spec/tmux_spec.lua`:

```lua
describe("persistent_term.tmux executor + helpers", function()
  local tmux

  before_each(function()
    package.loaded["persistent_term.tmux"] = nil
    tmux = require("persistent_term.tmux")
  end)

  it("parse_list_panes splits lines into {pane_id, name}", function()
    local rows = tmux.parse_list_panes("%12 dev\n%13 test\n%14 \n")
    assert.same({
      { pane_id = "%12", name = "dev" },
      { pane_id = "%13", name = "test" },
      { pane_id = "%14", name = "" },
    }, rows)
  end)

  it("parse_new_session_output splits ids", function()
    local r = tmux.parse_new_session_output("$3\t%12\t@7\n")
    assert.same({ session_id = "$3", pane_id = "%12", window_id = "@7" }, r)
  end)

  it("compare_versions handles 3.0a vs 3.0", function()
    assert.is_true(tmux.version_at_least("3.0", "3.0"))
    assert.is_true(tmux.version_at_least("3.1", "3.0"))
    assert.is_true(tmux.version_at_least("3.0a", "3.0"))
    assert.is_false(tmux.version_at_least("2.9", "3.0"))
  end)

  it("run executes argv and returns ok/stdout/stderr/code", function()
    -- Use a portable trivial command via the executor.
    local res = tmux.run({ "true" })
    assert.is_true(res.ok)
    assert.equals(0, res.code)
    local res2 = tmux.run({ "false" })
    assert.is_false(res2.ok)
    assert.is_true(res2.code ~= 0)
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/spec/tmux_spec.lua {minimal_init='tests/minimal_init.lua'}"`
Expected: 4 new failures (rest still pass).

- [ ] **Step 3: Extend `tmux.lua`**

Append below the `builders` table:

```lua
function M.run(argv, opts)
  opts = opts or {}
  local result = vim.system(argv, {
    text = true,
    timeout = opts.timeout or 5000,
    stdin = opts.stdin,
  }):wait()
  return {
    ok = result.code == 0,
    code = result.code,
    stdout = result.stdout or "",
    stderr = result.stderr or "",
  }
end

function M.parse_list_panes(stdout)
  local rows = {}
  for line in stdout:gmatch("[^\n]+") do
    local pane_id, name = line:match("^(%S+)%s*(.*)$")
    if pane_id then
      table.insert(rows, { pane_id = pane_id, name = name or "" })
    end
  end
  return rows
end

function M.parse_new_session_output(stdout)
  local trimmed = stdout:gsub("[\r\n]+$", "")
  local sid, pid, wid = trimmed:match("^(%S+)\t(%S+)\t(%S+)$")
  if not sid then
    return nil
  end
  return { session_id = sid, pane_id = pid, window_id = wid }
end

local function num_tuple(s)
  local out = {}
  for chunk in s:gmatch("(%d+)") do
    table.insert(out, tonumber(chunk))
  end
  return out
end

function M.version_at_least(have, want)
  -- tmux versions look like "3.0", "3.0a", "3.2-rc2". We extract just the
  -- numeric prefix tuple and compare.
  local h, w = num_tuple(have), num_tuple(want)
  for i = 1, math.max(#h, #w) do
    local a, b = h[i] or 0, w[i] or 0
    if a ~= b then
      return a > b
    end
  end
  return true
end

local version_cached = nil
function M.check_version(min)
  if version_cached ~= nil then
    return version_cached
  end
  local res = M.run(M.builders.version_check())
  if not res.ok then
    version_cached = { ok = false, reason = "tmux not found" }
    return version_cached
  end
  local v = res.stdout:match("tmux%s+(%S+)")
  if not v then
    version_cached = { ok = false, reason = "could not parse tmux version: " .. res.stdout }
    return version_cached
  end
  if not M.version_at_least(v, min) then
    version_cached = { ok = false, reason = string.format("tmux %s found; %s required", v, min) }
  else
    version_cached = { ok = true, version = v }
  end
  return version_cached
end

function M._reset_version_cache()
  version_cached = nil
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/spec/tmux_spec.lua {minimal_init='tests/minimal_init.lua'}"`
Expected: all tmux tests pass.

- [ ] **Step 5: Commit**

```bash
git add lua/persistent_term/tmux.lua tests/spec/tmux_spec.lua
git commit -m "feat(lua): tmux.run executor, list/new-session parsers, version check"
```

---

## Task 10: Lua — `bridge.lua` socket server + AUTH validation

**Files:**
- Create: `lua/persistent_term/bridge.lua`
- Create: `tests/spec/bridge_spec.lua`

- [ ] **Step 1: Write the failing tests**

```lua
-- tests/spec/bridge_spec.lua
local uv = vim.uv or vim.loop

local function wait_for(predicate, timeout_ms)
  timeout_ms = timeout_ms or 1000
  local deadline = uv.now() + timeout_ms
  while uv.now() < deadline do
    if predicate() then
      return true
    end
    vim.wait(20)
  end
  return false
end

local function client_send(sock_path, text, on_reply)
  local client = uv.new_pipe(false)
  client:connect(sock_path, function(err)
    assert(not err, err)
    client:write(text)
    client:read_start(function(rerr, data)
      if rerr or not data then
        client:close()
        return
      end
      on_reply(data)
    end)
  end)
  return client
end

describe("persistent_term.bridge server", function()
  local bridge

  before_each(function()
    package.loaded["persistent_term.bridge"] = nil
    bridge = require("persistent_term.bridge")
  end)

  it("accepts a connection with the correct token", function()
    local sock_path = vim.fn.tempname() .. ".sock"
    local attached = false
    local server = bridge.start_server({
      socket_path = sock_path,
      token = "GOOD",
      on_attach = function(_client)
        attached = true
      end,
      on_error = function(_) end,
    })

    local replies = {}
    client_send(sock_path, "AUTH GOOD\n", function(data)
      table.insert(replies, data)
    end)

    assert.is_true(wait_for(function()
      return #replies > 0 and attached
    end))
    assert.equals("OK\n", replies[1])
    server:close()
  end)

  it("rejects a wrong token and does not call on_attach", function()
    local sock_path = vim.fn.tempname() .. ".sock"
    local attached = false
    local server = bridge.start_server({
      socket_path = sock_path,
      token = "GOOD",
      on_attach = function(_) attached = true end,
      on_error = function(_) end,
    })

    local replies = {}
    client_send(sock_path, "AUTH BAD\n", function(data)
      table.insert(replies, data)
    end)

    assert.is_true(wait_for(function() return #replies > 0 end))
    assert.is_truthy(replies[1]:match("^ERR"))
    assert.is_false(attached)
    server:close()
  end)

  it("rejects a malformed handshake line", function()
    local sock_path = vim.fn.tempname() .. ".sock"
    local errors_seen = 0
    local server = bridge.start_server({
      socket_path = sock_path,
      token = "GOOD",
      on_attach = function(_) end,
      on_error = function(_) errors_seen = errors_seen + 1 end,
    })

    local replies = {}
    client_send(sock_path, "HELLO\n", function(data)
      table.insert(replies, data)
    end)

    assert.is_true(wait_for(function() return #replies > 0 end))
    assert.is_truthy(replies[1]:match("^ERR"))
    server:close()
  end)

  it("close() removes the socket file", function()
    local sock_path = vim.fn.tempname() .. ".sock"
    local server = bridge.start_server({
      socket_path = sock_path,
      token = "X",
      on_attach = function(_) end,
      on_error = function(_) end,
    })
    assert.equals(1, vim.fn.filereadable(sock_path) + (vim.fn.getftype(sock_path) == "socket" and 1 or 0) >= 1 and 1 or 0)
    server:close()
    assert.equals("", vim.fn.getftype(sock_path))
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/spec/bridge_spec.lua {minimal_init='tests/minimal_init.lua'}"`
Expected: failure — module not found.

- [ ] **Step 3: Implement `bridge.lua` (server portion)**

```lua
-- lua/persistent_term/bridge.lua
local uv = vim.uv or vim.loop

local M = {}

local AUTH_PATTERN = "^AUTH%s+(%S+)\n$"

local function reply(client, line)
  client:write(line, function() end)
end

local function handle_client_handshake(client, expected_token, on_attach, on_error)
  local buf = {}
  client:read_start(function(err, chunk)
    if err then
      on_error("read: " .. err)
      client:close()
      return
    end
    if not chunk then
      client:close()
      return
    end
    table.insert(buf, chunk)
    local line = table.concat(buf)
    -- We treat the AUTH line as the first newline-terminated chunk.
    if line:find("\n", 1, true) then
      client:read_stop()
      local token = line:match(AUTH_PATTERN)
      if not token then
        reply(client, "ERR malformed\n")
        on_error("malformed handshake: " .. vim.inspect(line))
        vim.defer_fn(function() client:close() end, 10)
        return
      end
      if token ~= expected_token then
        reply(client, "ERR auth\n")
        on_error("auth failed")
        vim.defer_fn(function() client:close() end, 10)
        return
      end
      reply(client, "OK\n")
      on_attach(client)
    end
  end)
end

local function bind_listen(socket_path, opts)
  local server = uv.new_pipe(false)
  -- Make sure no stale socket file is in the way.
  pcall(os.remove, socket_path)
  local ok, err = server:bind(socket_path)
  if not ok then
    server:close()
    error("bridge: bind " .. socket_path .. ": " .. tostring(err))
  end
  ok, err = server:listen(1, function(lerr)
    if lerr then
      opts.on_error("listen: " .. lerr)
      return
    end
    local client = uv.new_pipe(false)
    server:accept(client)
    handle_client_handshake(client, opts.token, opts.on_attach, opts.on_error)
  end)
  if not ok then
    server:close()
    error("bridge: listen " .. socket_path .. ": " .. tostring(err))
  end
  return server
end

function M.start_server(opts)
  assert(type(opts.socket_path) == "string", "socket_path required")
  assert(type(opts.token) == "string", "token required")
  assert(type(opts.on_attach) == "function", "on_attach required")
  assert(type(opts.on_error) == "function", "on_error required")
  local server = bind_listen(opts.socket_path, opts)
  local closed = false
  return {
    close = function()
      if closed then return end
      closed = true
      if not server:is_closing() then
        server:close()
      end
      pcall(os.remove, opts.socket_path)
    end,
  }
end

return M
```

- [ ] **Step 4: Run test to verify it passes**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/spec/bridge_spec.lua {minimal_init='tests/minimal_init.lua'}"`
Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add lua/persistent_term/bridge.lua tests/spec/bridge_spec.lua
git commit -m "feat(lua): bridge socket server with AUTH handshake"
```

---

## Task 11: Lua — `bridge.lua` data path (buffer + chan_send + on_input)

**Files:**
- Modify: `lua/persistent_term/bridge.lua`
- Modify: `tests/spec/bridge_spec.lua`

- [ ] **Step 1: Append the failing tests**

```lua
-- (appended to tests/spec/bridge_spec.lua)
describe("persistent_term.bridge data path", function()
  local bridge

  before_each(function()
    package.loaded["persistent_term.bridge"] = nil
    bridge = require("persistent_term.bridge")
  end)

  it("create_buffer returns a terminal-type buffer with a channel", function()
    local result = bridge.create_buffer("dev")
    assert.is_number(result.bufnr)
    assert.is_number(result.chan)
    assert.equals("terminal", vim.bo[result.bufnr].buftype)
    assert.equals("hide", vim.bo[result.bufnr].bufhidden)
    assert.equals(false, vim.bo[result.bufnr].swapfile)
    assert.equals("pterm://dev", vim.api.nvim_buf_get_name(result.bufnr))
    vim.api.nvim_buf_delete(result.bufnr, { force = true })
  end)

  it("attach pipes socket bytes into the buffer via chan_send", function()
    local sock_path = vim.fn.tempname() .. ".sock"
    local buf = bridge.create_buffer("test")
    local handle = {
      bufnr = buf.bufnr, chan = buf.chan,
      name = "test", pane_id = "%99",
    }
    local server = bridge.start_server({
      socket_path = sock_path,
      token = "T",
      on_attach = function(client)
        bridge.attach(handle, client)
      end,
      on_error = function(_) end,
    })

    -- Connect with a real Unix client and send bytes after AUTH.
    local uv = vim.uv or vim.loop
    local client = uv.new_pipe(false)
    client:connect(sock_path, function(err)
      assert(not err, err)
      client:write("AUTH T\n")
      vim.defer_fn(function()
        client:write("hello-from-pane\n")
      end, 50)
    end)

    local ok = vim.wait(2000, function()
      local lines = vim.api.nvim_buf_get_lines(buf.bufnr, 0, -1, false)
      for _, l in ipairs(lines) do
        if l:find("hello-from-pane", 1, true) then
          return true
        end
      end
      return false
    end)
    assert.is_true(ok)
    client:close()
    server:close()
    vim.api.nvim_buf_delete(buf.bufnr, { force = true })
  end)

  it("on_input writes user keystrokes back to the socket", function()
    local sock_path = vim.fn.tempname() .. ".sock"
    local buf = bridge.create_buffer("kb")
    local handle = { bufnr = buf.bufnr, chan = buf.chan, name = "kb", pane_id = "%1" }

    local received = {}
    local server = bridge.start_server({
      socket_path = sock_path,
      token = "T",
      on_attach = function(client)
        bridge.attach(handle, client)
        client:read_start(function(_, data)
          if data then
            table.insert(received, data)
          end
        end)
      end,
      on_error = function(_) end,
    })

    local uv = vim.uv or vim.loop
    local client = uv.new_pipe(false)
    client:connect(sock_path, function(err)
      assert(not err, err)
      client:write("AUTH T\n")
    end)

    -- Wait for handshake to land.
    assert.is_true(vim.wait(1000, function()
      return handle._attached == true
    end))

    -- Simulate user input via the underlying channel's on_input.
    -- nvim_chan_send is the pane->buffer direction; for the buffer->pane
    -- direction we call the on_input hook directly.
    handle._on_input("i", buf.chan, buf.bufnr, "ls\r")
    -- After on_input forwards bytes through attach(), the server should
    -- have read "ls\r" plus the prior AUTH line on the channel.
    assert.is_true(vim.wait(1000, function()
      for _, chunk in ipairs(received) do
        if chunk:find("ls\r", 1, true) then return true end
      end
      return false
    end))

    client:close()
    server:close()
    vim.api.nvim_buf_delete(buf.bufnr, { force = true })
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/spec/bridge_spec.lua {minimal_init='tests/minimal_init.lua'}"`
Expected: the 3 new tests fail (`create_buffer` / `attach` undefined).

- [ ] **Step 3: Extend `bridge.lua`**

Append to `lua/persistent_term/bridge.lua`:

```lua
local function rename_buffer(bufnr, name)
  pcall(vim.api.nvim_buf_set_name, bufnr, name)
end

local function set_buffer_options(bufnr)
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
end

function M.create_buffer(name)
  local bufnr = vim.api.nvim_create_buf(true, false)
  local handle = { _on_input = function() end }
  local chan = vim.api.nvim_open_term(bufnr, {
    on_input = function(event, term, bnr, data)
      handle._on_input(event, term, bnr, data)
    end,
  })
  set_buffer_options(bufnr)
  rename_buffer(bufnr, "pterm://" .. name)
  vim.b[bufnr].persistent_term_name = name
  return {
    bufnr = bufnr,
    chan = chan,
    _on_input_holder = handle,
  }
end

function M.attach(handle, client)
  handle._attached = true
  handle.client = client
  handle._pending_writes = 0

  -- Pane -> buffer.
  client:read_start(function(err, data)
    if err then
      vim.schedule(function()
        M.detach(handle, "socket read: " .. err)
      end)
      return
    end
    if not data then
      vim.schedule(function()
        M.detach(handle, "socket eof")
      end)
      return
    end
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(handle.bufnr) then
        vim.api.nvim_chan_send(handle.chan, data)
      end
    end)
  end)

  -- Buffer -> pane. Wire the per-buffer handle's on_input now.
  local function on_input(_event, _term, _bnr, data)
    if handle._closing or not client or client:is_closing() then return end
    if handle._pending_writes > 64 * 1024 then
      require("persistent_term.log").warn(
        "persistent-term: input queue full for " .. (handle.name or "?") .. "; dropping keystroke"
      )
      return
    end
    handle._pending_writes = handle._pending_writes + #data
    client:write(data, function(werr)
      handle._pending_writes = math.max(0, handle._pending_writes - #data)
      if werr then
        vim.schedule(function()
          M.detach(handle, "socket write: " .. werr)
        end)
      end
    end)
  end

  -- Find the holder placed there by create_buffer. The caller is expected
  -- to give us the same handle table that create_buffer returned, so the
  -- holder is reachable through it.
  if handle._on_input_holder then
    handle._on_input_holder._on_input = on_input
  end
  handle._on_input = on_input
end

function M.detach(handle, reason)
  if handle._closing then return end
  handle._closing = true
  if handle.client and not handle.client:is_closing() then
    handle.client:close()
  end
  if handle._server and type(handle._server.close) == "function" then
    pcall(handle._server.close, handle._server)
    handle._server = nil
  end
  if handle._resize_timer and not handle._resize_timer:is_closing() then
    handle._resize_timer:stop()
    handle._resize_timer:close()
    handle._resize_timer = nil
  end
  if handle._on_input_holder then
    handle._on_input_holder._on_input = function() end
  end
  if vim.api.nvim_buf_is_valid(handle.bufnr) then
    rename_buffer(handle.bufnr, "pterm://" .. (handle.name or "?") .. " [detached]")
  end
  if reason then
    require("persistent_term.log").warn(
      "persistent-term: bridge detached: " .. reason
    )
  end
end
```

Adjust `create_buffer` so the result table contains `_on_input_holder` and update the test's `handle` table accordingly to pass the holder along:

```lua
-- update where the test builds `handle`:
local handle = {
  bufnr = buf.bufnr, chan = buf.chan,
  name = "test", pane_id = "%99",
  _on_input_holder = buf._on_input_holder,
}
```

(Apply the same to all three tests in `bridge_spec.lua` that build a `handle` table.)

- [ ] **Step 4: Run test to verify it passes**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/spec/bridge_spec.lua {minimal_init='tests/minimal_init.lua'}"`
Expected: all bridge tests pass.

- [ ] **Step 5: Commit**

```bash
git add lua/persistent_term/bridge.lua tests/spec/bridge_spec.lua
git commit -m "feat(lua): bridge data path (chan_send + on_input + detach)"
```

---

## Task 12: Lua — `bridge.lua` resize forwarding

**Files:**
- Modify: `lua/persistent_term/bridge.lua`
- Modify: `tests/spec/bridge_spec.lua`

- [ ] **Step 1: Append the failing test**

```lua
-- (appended to tests/spec/bridge_spec.lua)
describe("persistent_term.bridge resize", function()
  local bridge

  before_each(function()
    package.loaded["persistent_term.bridge"] = nil
    bridge = require("persistent_term.bridge")
  end)

  it("debounces resize and calls tmux resize-pane once per burst", function()
    local called = {}
    local fake_tmux = {
      builders = require("persistent_term.tmux").builders,
      run = function(argv)
        table.insert(called, argv)
        return { ok = true, code = 0, stdout = "", stderr = "" }
      end,
    }
    package.loaded["persistent_term.tmux"] = fake_tmux

    local buf = bridge.create_buffer("rz")
    local handle = {
      bufnr = buf.bufnr, chan = buf.chan,
      name = "rz", pane_id = "%42",
      _on_input_holder = buf._on_input_holder,
    }

    -- Fire 5 resize requests in quick succession.
    for _ = 1, 5 do
      bridge.resize_to(handle, 80, 24)
    end
    -- Debounce window is 50ms; wait 200ms for the timer to fire.
    vim.wait(200)

    assert.equals(1, #called)
    local argv = called[1]
    -- last 4 elements: -x 80 -y 24
    assert.equals("-x", argv[#argv - 3])
    assert.equals("80", argv[#argv - 2])
    assert.equals("-y", argv[#argv - 1])
    assert.equals("24", argv[#argv])

    vim.api.nvim_buf_delete(buf.bufnr, { force = true })
    package.loaded["persistent_term.tmux"] = nil
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/spec/bridge_spec.lua {minimal_init='tests/minimal_init.lua'}"`
Expected: `resize_to` undefined.

- [ ] **Step 3: Add resize logic to `bridge.lua`**

Append:

```lua
local RESIZE_DEBOUNCE_MS = 50

function M.resize_to(handle, cols, rows)
  handle._pending_size = { cols = cols, rows = rows }
  if handle._resize_timer then
    handle._resize_timer:stop()
    handle._resize_timer:close()
    handle._resize_timer = nil
  end
  local timer = uv.new_timer()
  handle._resize_timer = timer
  timer:start(RESIZE_DEBOUNCE_MS, 0, function()
    vim.schedule(function()
      if not handle._pending_size then return end
      local size = handle._pending_size
      handle._pending_size = nil
      if not handle.pane_id then return end
      local tmux = require("persistent_term.tmux")
      local argv = tmux.builders.resize_pane(handle.pane_id, size.cols, size.rows)
      local res = tmux.run(argv)
      if not res.ok then
        require("persistent_term.log").warn(
          string.format("resize-pane failed for %s: %s", handle.pane_id, res.stderr)
        )
      end
    end)
    if not timer:is_closing() then
      timer:close()
    end
    if handle._resize_timer == timer then
      handle._resize_timer = nil
    end
  end)
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/spec/bridge_spec.lua {minimal_init='tests/minimal_init.lua'}"`
Expected: all bridge tests pass.

- [ ] **Step 5: Commit**

```bash
git add lua/persistent_term/bridge.lua tests/spec/bridge_spec.lua
git commit -m "feat(lua): debounced resize forwarding through tmux resize-pane"
```

---

## Task 13: Lua — `bridge.lua` kill path + buffer wipe hook

**Files:**
- Modify: `lua/persistent_term/bridge.lua`
- Modify: `tests/spec/bridge_spec.lua`

- [ ] **Step 1: Append the failing test**

```lua
-- (appended to tests/spec/bridge_spec.lua)
describe("persistent_term.bridge kill / wipe", function()
  local bridge

  before_each(function()
    package.loaded["persistent_term.bridge"] = nil
    bridge = require("persistent_term.bridge")
  end)

  it("kill closes the bridge and wipes the buffer", function()
    local called = {}
    package.loaded["persistent_term.tmux"] = {
      builders = require("persistent_term.tmux").builders,
      run = function(argv)
        table.insert(called, argv)
        return { ok = true, code = 0, stdout = "", stderr = "" }
      end,
    }

    local buf = bridge.create_buffer("kx")
    local handle = {
      bufnr = buf.bufnr, chan = buf.chan,
      name = "kx", pane_id = "%55",
      _on_input_holder = buf._on_input_holder,
    }

    bridge.kill(handle)
    assert.is_false(vim.api.nvim_buf_is_valid(buf.bufnr))
    local found_kill = false
    for _, argv in ipairs(called) do
      if argv[#argv - 1] == "-t" and argv[#argv] == "%55" then
        found_kill = true
      end
    end
    assert.is_true(found_kill)
    package.loaded["persistent_term.tmux"] = nil
  end)

  it("install_buffer_hook runs detach on BufWipeout", function()
    local detached = false
    package.loaded["persistent_term.tmux"] = {
      builders = require("persistent_term.tmux").builders,
      run = function() return { ok = true, code = 0, stdout = "", stderr = "" } end,
    }

    local buf = bridge.create_buffer("hk")
    local handle = {
      bufnr = buf.bufnr, chan = buf.chan,
      name = "hk", pane_id = "%66",
      _on_input_holder = buf._on_input_holder,
      _on_detach = function() detached = true end,
    }
    bridge.install_buffer_hook(handle)

    vim.api.nvim_buf_delete(buf.bufnr, { force = true })
    assert.is_true(detached)
    package.loaded["persistent_term.tmux"] = nil
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/spec/bridge_spec.lua {minimal_init='tests/minimal_init.lua'}"`
Expected: `kill` / `install_buffer_hook` undefined.

- [ ] **Step 3: Add kill + hook**

Append to `bridge.lua`:

```lua
function M.kill(handle)
  if handle.pane_id then
    local tmux = require("persistent_term.tmux")
    local res = tmux.run(tmux.builders.kill_pane(handle.pane_id))
    if not res.ok then
      require("persistent_term.log").warn(
        "kill-pane failed for " .. handle.pane_id .. ": " .. res.stderr
      )
    end
  end
  M.detach(handle, "kill")
  if vim.api.nvim_buf_is_valid(handle.bufnr) then
    vim.api.nvim_buf_delete(handle.bufnr, { force = true })
  end
end

local function buf_size_for(bufnr)
  local cols, rows
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == bufnr then
      local w = vim.api.nvim_win_get_width(win)
      local h = vim.api.nvim_win_get_height(win)
      if not cols or w < cols then cols = w end
      if not rows or h < rows then rows = h end
    end
  end
  return cols, rows
end

function M.install_buffer_hook(handle)
  local group = vim.api.nvim_create_augroup("PersistentTerm_" .. handle.bufnr, { clear = true })
  vim.api.nvim_create_autocmd("BufWipeout", {
    group = group,
    buffer = handle.bufnr,
    once = true,
    callback = function()
      M.detach(handle, "buffer wiped")
      if handle._on_detach then
        handle._on_detach()
      end
    end,
  })
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group = group,
    callback = function()
      if handle._closing then return end
      local cols, rows = buf_size_for(handle.bufnr)
      if cols and rows then
        M.resize_to(handle, cols, rows)
      end
    end,
  })
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/spec/bridge_spec.lua {minimal_init='tests/minimal_init.lua'}"`
Expected: all bridge tests pass.

- [ ] **Step 5: Commit**

```bash
git add lua/persistent_term/bridge.lua tests/spec/bridge_spec.lua
git commit -m "feat(lua): bridge kill path + BufWipeout autocmd hook"
```

---

## Task 14: Lua — `command.lua` argv parser for `:PTerm`

**Files:**
- Create: `lua/persistent_term/command.lua`
- Create: `tests/spec/command_spec.lua`

- [ ] **Step 1: Write the failing tests**

```lua
-- tests/spec/command_spec.lua
describe("persistent_term.command parse_open_args", function()
  local command

  before_each(function()
    package.loaded["persistent_term.command"] = nil
    command = require("persistent_term.command")
  end)

  it("parses `dev -- npm run dev`", function()
    local r, err = command.parse_open_args("dev -- npm run dev")
    assert.is_nil(err)
    assert.equals("dev", r.name)
    assert.same({ "npm", "run", "dev" }, r.argv)
  end)

  it("rejects missing --", function()
    local r, err = command.parse_open_args("dev npm run dev")
    assert.is_nil(r)
    assert.is_truthy(err:match("%-%-"))
  end)

  it("rejects empty argv after --", function()
    local r, err = command.parse_open_args("dev --")
    assert.is_nil(r)
    assert.is_truthy(err:match("empty"))
  end)

  it("rejects names with bad characters", function()
    for _, bad in ipairs({ "dev/x", "dev x", "dev'", "../foo", "" }) do
      local _, err = command.parse_open_args(bad .. " -- ls")
      assert.is_truthy(err, "expected error for name " .. bad)
    end
  end)

  it("accepts names with safe characters", function()
    for _, good in ipairs({ "dev", "DEV1", "my.app", "a_b", "a-b" }) do
      local r, err = command.parse_open_args(good .. " -- ls")
      assert.is_nil(err)
      assert.equals(good, r.name)
    end
  end)

  it("preserves multiple spaces in argv elements", function()
    local r = command.parse_open_args('dev -- sh -c "echo hi"')
    assert.same({ "sh", "-c", '"echo hi"' }, r.argv)
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/spec/command_spec.lua {minimal_init='tests/minimal_init.lua'}"`
Expected: failure — module not found.

- [ ] **Step 3: Implement the parser**

```lua
-- lua/persistent_term/command.lua
local M = {}

local NAME_PATTERN = "^[A-Za-z0-9_.-]+$"

local function split_words(s)
  local out = {}
  for w in s:gmatch("%S+") do
    table.insert(out, w)
  end
  return out
end

function M.parse_open_args(raw)
  if type(raw) ~= "string" or raw == "" then
    return nil, "usage: :PTerm {name} -- {cmd...}"
  end
  local words = split_words(raw)
  if #words == 0 then
    return nil, "usage: :PTerm {name} -- {cmd...}"
  end
  local name = words[1]
  if #name > 64 or not name:match(NAME_PATTERN) then
    return nil, "invalid name (must match [A-Za-z0-9_.-]{1,64}): " .. name
  end
  -- find "--" separator
  local sep_index = nil
  for i = 2, #words do
    if words[i] == "--" then
      sep_index = i
      break
    end
  end
  if not sep_index then
    return nil, "missing -- separator before command"
  end
  if sep_index == #words then
    return nil, "empty command after --"
  end
  local argv = {}
  for i = sep_index + 1, #words do
    table.insert(argv, words[i])
  end
  return { name = name, argv = argv }
end

return M
```

- [ ] **Step 4: Run test to verify it passes**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/spec/command_spec.lua {minimal_init='tests/minimal_init.lua'}"`
Expected: all parser tests pass.

- [ ] **Step 5: Commit**

```bash
git add lua/persistent_term/command.lua tests/spec/command_spec.lua
git commit -m "feat(lua): :PTerm argv parser with name validation"
```

---

## Task 15: Lua — `command.lua` :PTerm execution (orchestration)

**Files:**
- Modify: `lua/persistent_term/command.lua`
- Modify: `tests/spec/command_spec.lua`

- [ ] **Step 1: Append the failing tests**

```lua
-- (appended to tests/spec/command_spec.lua)
describe("persistent_term.command.cmd_open", function()
  local command
  local original_tmux

  before_each(function()
    package.loaded["persistent_term.command"] = nil
    package.loaded["persistent_term.bridge"] = nil
    original_tmux = package.loaded["persistent_term.tmux"]
  end)

  after_each(function()
    package.loaded["persistent_term.tmux"] = original_tmux
  end)

  it("orchestrates: pre-flight, dup check, new-session, options, pipe-pane", function()
    local calls = {}
    local fake_builders = require("persistent_term.tmux").builders
    package.loaded["persistent_term.tmux"] = {
      builders = fake_builders,
      check_version = function(_) return { ok = true, version = "3.4" } end,
      parse_list_panes = require("persistent_term.tmux").parse_list_panes,
      parse_new_session_output = require("persistent_term.tmux").parse_new_session_output,
      run = function(argv)
        table.insert(calls, argv)
        local sub = argv[4]
        if sub == "list-panes" then
          return { ok = true, code = 0, stdout = "", stderr = "" }
        elseif sub == "new-session" then
          return { ok = true, code = 0, stdout = "$1\t%10\t@2\n", stderr = "" }
        end
        return { ok = true, code = 0, stdout = "", stderr = "" }
      end,
    }
    package.loaded["persistent_term.install"] = {
      binary_path = function() return "/tmp/persistent-term-pipe" end,
      is_installed = function() return true end,
    }
    -- stub bridge so it does not try to bind a real socket
    package.loaded["persistent_term.bridge"] = {
      create_buffer = function(name)
        local bufnr = vim.api.nvim_create_buf(true, true)
        return { bufnr = bufnr, chan = -1, _on_input_holder = { _on_input = function() end } }
      end,
      start_server = function(opts)
        -- simulate immediate attach success
        vim.defer_fn(function() opts.on_attach({ is_closing = function() return false end, close = function() end, write = function() end, read_start = function() end }) end, 10)
        return { close = function() end }
      end,
      attach = function(_, _) end,
      install_buffer_hook = function(_) end,
      resize_to = function(_, _, _) end,
      detach = function(_, _) end,
      kill = function(_) end,
    }

    command = require("persistent_term.command")
    local handle, err = command.cmd_open("dev -- bash -c hi")
    assert.is_nil(err)
    assert.is_truthy(handle)

    -- Verify the sequence: list-panes (dup), new-session, set-window-option,
    -- set-pane-option, pipe-pane.
    local subs = {}
    for _, argv in ipairs(calls) do
      table.insert(subs, argv[4])
    end
    assert.same(
      { "list-panes", "new-session", "set-option", "set-option", "pipe-pane" },
      subs
    )
    vim.api.nvim_buf_delete(handle.bufnr, { force = true })
  end)

  it("refuses when a name already exists", function()
    package.loaded["persistent_term.tmux"] = {
      builders = require("persistent_term.tmux").builders,
      check_version = function(_) return { ok = true, version = "3.4" } end,
      parse_list_panes = require("persistent_term.tmux").parse_list_panes,
      run = function(_) return { ok = true, code = 0, stdout = "%99 dev\n", stderr = "" } end,
    }
    package.loaded["persistent_term.install"] = {
      binary_path = function() return "/tmp/x" end,
      is_installed = function() return true end,
    }
    package.loaded["persistent_term.bridge"] = {
      create_buffer = function() error("should not be called") end,
    }
    command = require("persistent_term.command")
    local handle, err = command.cmd_open("dev -- bash")
    assert.is_nil(handle)
    assert.is_truthy(err:match("already exists"))
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/spec/command_spec.lua {minimal_init='tests/minimal_init.lua'}"`
Expected: `cmd_open` undefined.

- [ ] **Step 3: Implement `cmd_open` in `command.lua`**

Append to `command.lua`:

```lua
local function dir_for_socket()
  local xdg = vim.env.XDG_RUNTIME_DIR
  if xdg and xdg ~= "" then
    return xdg .. "/persistent-term"
  end
  return "/tmp/persistent-term-" .. vim.fn.getpid()
end

local function ensure_runtime_dir(dir)
  vim.fn.mkdir(dir, "p", "0700")
end

local function random_hex(nbytes)
  local uv = vim.uv or vim.loop
  local raw = uv.random and uv.random(nbytes) or nil
  if not raw then
    -- Fallback: use os.time+random; only reached on very old runtimes.
    math.randomseed(os.time())
    local t = {}
    for _ = 1, nbytes do
      table.insert(t, string.char(math.random(0, 255)))
    end
    raw = table.concat(t)
  end
  return (raw:gsub(".", function(c) return string.format("%02x", string.byte(c)) end))
end

local function buf_size(bufnr)
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(win) == bufnr then
      return vim.api.nvim_win_get_width(win), vim.api.nvim_win_get_height(win)
    end
  end
  return vim.o.columns, math.max(vim.o.lines - 2, 5)
end

local function name_in_use(rows, name)
  for _, row in ipairs(rows) do
    if row.name == name then
      return row.pane_id
    end
  end
  return nil
end

function M.cmd_open(raw)
  local parsed, perr = M.parse_open_args(raw)
  if not parsed then
    return nil, perr
  end

  local tmux = require("persistent_term.tmux")
  local install = require("persistent_term.install")
  local bridge = require("persistent_term.bridge")
  local log = require("persistent_term.log")

  local v = tmux.check_version("3.0")
  if not v.ok then
    log.error(v.reason)
    return nil, v.reason
  end
  if not install.is_installed() then
    local msg = "helper binary not installed; run :PTermInstall"
    log.error(msg)
    return nil, msg
  end

  local list = tmux.run(tmux.builders.list_panes())
  if not list.ok then
    return nil, "tmux list-panes failed: " .. list.stderr
  end
  local existing_pid = name_in_use(tmux.parse_list_panes(list.stdout), parsed.name)
  if existing_pid then
    return nil, string.format('terminal "%s" already exists (pane %s)', parsed.name, existing_pid)
  end

  local dir = dir_for_socket()
  ensure_runtime_dir(dir)
  local socket_path = dir .. "/" .. random_hex(16) .. ".sock"
  local token = random_hex(32)

  local buf = bridge.create_buffer(parsed.name)
  local cols, rows = buf_size(buf.bufnr)

  local handle = {
    bufnr = buf.bufnr, chan = buf.chan,
    name = parsed.name,
    _on_input_holder = buf._on_input_holder,
    _on_detach = function() end,
  }

  local server
  server = bridge.start_server({
    socket_path = socket_path,
    token = token,
    on_attach = function(client)
      handle._attached = true
      bridge.attach(handle, client)
    end,
    on_error = function(reason)
      log.warn("bridge: " .. reason)
    end,
  })
  handle._server = server

  -- Handshake watchdog: if the helper does not connect+AUTH within 2s,
  -- tear down the partial state.
  vim.defer_fn(function()
    if handle._attached or handle._closing then return end
    log.error(string.format('handshake timeout for "%s"; rolling back', parsed.name))
    if handle.pane_id then
      tmux.run(tmux.builders.kill_pane(handle.pane_id))
    end
    bridge.detach(handle, "handshake timeout")
    if vim.api.nvim_buf_is_valid(handle.bufnr) then
      vim.api.nvim_buf_delete(handle.bufnr, { force = true })
    end
  end, 2000)

  local new = tmux.run(tmux.builders.new_session({
    session_name = "pterm_" .. random_hex(4) .. "_" .. parsed.name,
    cols = cols,
    rows = rows,
    cwd = vim.fn.getcwd(),
    argv = parsed.argv,
  }))
  if not new.ok then
    server:close()
    pcall(vim.api.nvim_buf_delete, buf.bufnr, { force = true })
    return nil, "tmux new-session failed: " .. new.stderr
  end
  local ids = tmux.parse_new_session_output(new.stdout)
  if not ids then
    server:close()
    pcall(vim.api.nvim_buf_delete, buf.bufnr, { force = true })
    return nil, "tmux returned unparseable ids: " .. new.stdout
  end
  handle.pane_id = ids.pane_id
  handle.session_id = ids.session_id
  handle.window_id = ids.window_id
  vim.b[buf.bufnr].persistent_term_pane_id = ids.pane_id
  vim.b[buf.bufnr].persistent_term_session_id = ids.session_id

  tmux.run(tmux.builders.set_window_option(ids.window_id, "remain-on-exit", "on"))
  tmux.run(tmux.builders.set_pane_option(ids.pane_id, "@pterm_name", parsed.name))

  local helper = install.binary_path()
  local pipe = tmux.run(tmux.builders.pipe_pane({
    pane_id = ids.pane_id,
    bin_path = helper,
    socket_path = socket_path,
    token = token,
  }))
  if not pipe.ok then
    tmux.run(tmux.builders.kill_pane(ids.pane_id))
    server:close()
    pcall(vim.api.nvim_buf_delete, buf.bufnr, { force = true })
    return nil, "tmux pipe-pane failed: " .. pipe.stderr
  end

  bridge.install_buffer_hook(handle)
  return handle
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/spec/command_spec.lua {minimal_init='tests/minimal_init.lua'}"`
Expected: all tests pass.

- [ ] **Step 5: Commit**

```bash
git add lua/persistent_term/command.lua tests/spec/command_spec.lua
git commit -m "feat(lua): :PTerm execution orchestrates tmux + bridge + install"
```

---

## Task 16: Lua — `command.lua` :PTermAttach (with completion + scrollback)

**Files:**
- Modify: `lua/persistent_term/command.lua`
- Modify: `tests/spec/command_spec.lua`

- [ ] **Step 1: Append the failing tests**

```lua
-- (appended to tests/spec/command_spec.lua)
describe("persistent_term.command.cmd_attach + complete_attach", function()
  before_each(function()
    package.loaded["persistent_term.command"] = nil
    package.loaded["persistent_term.bridge"] = nil
  end)

  it("complete_attach returns names and pane_ids from list-panes", function()
    package.loaded["persistent_term.tmux"] = {
      builders = require("persistent_term.tmux").builders,
      check_version = function(_) return { ok = true } end,
      parse_list_panes = require("persistent_term.tmux").parse_list_panes,
      run = function(_)
        return { ok = true, code = 0, stdout = "%12 dev\n%13 test\n%14 \n", stderr = "" }
      end,
    }
    local cmd = require("persistent_term.command")
    local items = cmd.complete_attach("", "PTermAttach ", 12)
    table.sort(items)
    assert.same({ "%12", "%13", "%14", "dev", "test" }, items)
  end)

  it("complete_attach filters by prefix", function()
    package.loaded["persistent_term.tmux"] = {
      builders = require("persistent_term.tmux").builders,
      check_version = function(_) return { ok = true } end,
      parse_list_panes = require("persistent_term.tmux").parse_list_panes,
      run = function(_)
        return { ok = true, code = 0, stdout = "%12 dev\n%13 dx\n%14 other\n", stderr = "" }
      end,
    }
    local cmd = require("persistent_term.command")
    local items = cmd.complete_attach("d", "PTermAttach d", 13)
    table.sort(items)
    assert.same({ "dev", "dx" }, items)
  end)

  it("cmd_attach by name: replay history then pipe-pane", function()
    local calls = {}
    package.loaded["persistent_term.tmux"] = {
      builders = require("persistent_term.tmux").builders,
      check_version = function(_) return { ok = true, version = "3.4" } end,
      parse_list_panes = require("persistent_term.tmux").parse_list_panes,
      run = function(argv)
        table.insert(calls, argv)
        if argv[4] == "list-panes" then
          return { ok = true, stdout = "%12 dev\n", code = 0, stderr = "" }
        elseif argv[4] == "capture-pane" then
          return { ok = true, stdout = "history line\n", code = 0, stderr = "" }
        end
        return { ok = true, stdout = "", code = 0, stderr = "" }
      end,
    }
    package.loaded["persistent_term.install"] = {
      binary_path = function() return "/tmp/h" end,
      is_installed = function() return true end,
    }
    local sent = {}
    package.loaded["persistent_term.bridge"] = {
      create_buffer = function(name)
        local bufnr = vim.api.nvim_create_buf(true, true)
        return { bufnr = bufnr, chan = -1, _on_input_holder = { _on_input = function() end } }
      end,
      start_server = function(opts)
        vim.defer_fn(function() opts.on_attach({ is_closing = function() return false end, close = function() end, write = function() end, read_start = function() end }) end, 10)
        return { close = function() end }
      end,
      attach = function(_, _) end,
      install_buffer_hook = function(_) end,
      chan_send_history = function(_, data) table.insert(sent, data) end,
    }
    local cmd = require("persistent_term.command")
    local handle, err = cmd.cmd_attach("dev")
    assert.is_nil(err)
    assert.is_truthy(handle)
    assert.equals("%12", handle.pane_id)
    -- capture-pane should appear before pipe-pane
    local capture_idx, pipe_idx
    for i, argv in ipairs(calls) do
      if argv[4] == "capture-pane" then capture_idx = i end
      if argv[4] == "pipe-pane" then pipe_idx = i end
    end
    assert.is_truthy(capture_idx and pipe_idx and capture_idx < pipe_idx)
    assert.same({ "history line\n" }, sent)
    vim.api.nvim_buf_delete(handle.bufnr, { force = true })
  end)

  it("cmd_attach by raw pane_id works without name lookup", function()
    package.loaded["persistent_term.tmux"] = {
      builders = require("persistent_term.tmux").builders,
      check_version = function(_) return { ok = true, version = "3.4" } end,
      parse_list_panes = require("persistent_term.tmux").parse_list_panes,
      run = function(argv)
        if argv[4] == "list-panes" then
          return { ok = true, stdout = "%12 \n", code = 0, stderr = "" }
        elseif argv[4] == "capture-pane" then
          return { ok = true, stdout = "", code = 0, stderr = "" }
        end
        return { ok = true, stdout = "", code = 0, stderr = "" }
      end,
    }
    package.loaded["persistent_term.install"] = {
      binary_path = function() return "/tmp/h" end,
      is_installed = function() return true end,
    }
    package.loaded["persistent_term.bridge"] = {
      create_buffer = function(name)
        local bufnr = vim.api.nvim_create_buf(true, true)
        return { bufnr = bufnr, chan = -1, _on_input_holder = { _on_input = function() end } }
      end,
      start_server = function(opts)
        vim.defer_fn(function() opts.on_attach({ is_closing = function() return false end, close = function() end, write = function() end, read_start = function() end }) end, 10)
        return { close = function() end }
      end,
      attach = function(_, _) end,
      install_buffer_hook = function(_) end,
      chan_send_history = function(_, _) end,
    }
    local cmd = require("persistent_term.command")
    local handle, err = cmd.cmd_attach("%12")
    assert.is_nil(err)
    assert.equals("%12", handle.pane_id)
    vim.api.nvim_buf_delete(handle.bufnr, { force = true })
  end)

  it("cmd_attach refuses unknown name", function()
    package.loaded["persistent_term.tmux"] = {
      builders = require("persistent_term.tmux").builders,
      check_version = function(_) return { ok = true } end,
      parse_list_panes = require("persistent_term.tmux").parse_list_panes,
      run = function(_) return { ok = true, stdout = "%99 other\n", code = 0, stderr = "" } end,
    }
    package.loaded["persistent_term.install"] = {
      binary_path = function() return "/tmp/h" end,
      is_installed = function() return true end,
    }
    local cmd = require("persistent_term.command")
    local handle, err = cmd.cmd_attach("ghost")
    assert.is_nil(handle)
    assert.is_truthy(err:match("unknown"))
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/spec/command_spec.lua {minimal_init='tests/minimal_init.lua'}"`
Expected: `complete_attach` / `cmd_attach` undefined; also `bridge.chan_send_history` missing.

- [ ] **Step 3: Add `chan_send_history` in `bridge.lua`**

Append:

```lua
function M.chan_send_history(handle, data)
  if data == nil or data == "" then return end
  if not vim.api.nvim_buf_is_valid(handle.bufnr) then return end
  vim.api.nvim_chan_send(handle.chan, data)
end
```

- [ ] **Step 4: Implement `complete_attach` and `cmd_attach` in `command.lua`**

```lua
local PANE_ID_PATTERN = "^%%[0-9]+$"

local function list_known(tmux)
  local res = tmux.run(tmux.builders.list_panes())
  if not res.ok then
    return {}, "tmux list-panes failed: " .. res.stderr
  end
  return tmux.parse_list_panes(res.stdout)
end

function M.complete_attach(arg_lead, _cmd_line, _cursor_pos)
  local tmux = require("persistent_term.tmux")
  local rows = list_known(tmux)
  local out = {}
  for _, row in ipairs(rows) do
    if row.name ~= "" then
      table.insert(out, row.name)
    end
    table.insert(out, row.pane_id)
  end
  if arg_lead == "" then
    return out
  end
  local filtered = {}
  for _, item in ipairs(out) do
    if vim.startswith(item, arg_lead) then
      table.insert(filtered, item)
    end
  end
  return filtered
end

local function find_pane(rows, target)
  if target:match(PANE_ID_PATTERN) then
    for _, r in ipairs(rows) do
      if r.pane_id == target then return r end
    end
  else
    for _, r in ipairs(rows) do
      if r.name == target then return r end
    end
  end
  return nil
end

function M.cmd_attach(target)
  if type(target) ~= "string" or target == "" then
    return nil, "usage: :PTermAttach {name|pane_id}"
  end
  local tmux = require("persistent_term.tmux")
  local install = require("persistent_term.install")
  local bridge = require("persistent_term.bridge")
  local log = require("persistent_term.log")

  local v = tmux.check_version("3.0")
  if not v.ok then return nil, v.reason end
  if not install.is_installed() then
    return nil, "helper binary not installed; run :PTermInstall"
  end

  local list = tmux.run(tmux.builders.list_panes())
  if not list.ok then return nil, "tmux list-panes failed: " .. list.stderr end
  local rows = tmux.parse_list_panes(list.stdout)
  local row = find_pane(rows, target)
  if not row then
    return nil, "unknown pane: " .. target
  end

  local pane_id = row.pane_id
  local name = (row.name ~= "" and row.name) or pane_id

  -- If a pterm://{name} buffer is already attached, focus it.
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local bname = vim.api.nvim_buf_get_name(bufnr)
      if bname == "pterm://" .. name then
        vim.cmd.buffer(bufnr)
        return { bufnr = bufnr, pane_id = pane_id, name = name }
      end
    end
  end

  local dir = dir_for_socket()
  ensure_runtime_dir(dir)
  local socket_path = dir .. "/" .. random_hex(16) .. ".sock"
  local token = random_hex(32)
  local buf = bridge.create_buffer(name)
  local handle = {
    bufnr = buf.bufnr, chan = buf.chan,
    name = name, pane_id = pane_id,
    _on_input_holder = buf._on_input_holder,
  }

  -- Replay scrollback.
  local cap = tmux.run(tmux.builders.capture_pane(pane_id))
  if cap.ok and cap.stdout and cap.stdout ~= "" then
    bridge.chan_send_history(handle, cap.stdout)
  end

  local server
  server = bridge.start_server({
    socket_path = socket_path,
    token = token,
    on_attach = function(client)
      handle._attached = true
      bridge.attach(handle, client)
    end,
    on_error = function(reason)
      log.warn("bridge: " .. reason)
    end,
  })
  handle._server = server

  vim.defer_fn(function()
    if handle._attached or handle._closing then return end
    log.error(string.format('handshake timeout while attaching to %s', pane_id))
    bridge.detach(handle, "handshake timeout")
    if vim.api.nvim_buf_is_valid(handle.bufnr) then
      vim.api.nvim_buf_delete(handle.bufnr, { force = true })
    end
  end, 2000)

  local helper = install.binary_path()
  local pipe = tmux.run(tmux.builders.pipe_pane({
    pane_id = pane_id,
    bin_path = helper,
    socket_path = socket_path,
    token = token,
  }))
  if not pipe.ok then
    server:close()
    pcall(vim.api.nvim_buf_delete, buf.bufnr, { force = true })
    return nil, "tmux pipe-pane failed: " .. pipe.stderr
  end

  vim.b[buf.bufnr].persistent_term_pane_id = pane_id
  bridge.install_buffer_hook(handle)
  return handle
end
```

- [ ] **Step 5: Run test to verify it passes**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/spec/command_spec.lua {minimal_init='tests/minimal_init.lua'}"`
Expected: all command tests pass.

- [ ] **Step 6: Commit**

```bash
git add lua/persistent_term/command.lua lua/persistent_term/bridge.lua tests/spec/command_spec.lua
git commit -m "feat(lua): :PTermAttach with completion and capture-pane replay"
```

---

## Task 17: Lua — `command.lua` :PTermKill

**Files:**
- Modify: `lua/persistent_term/command.lua`
- Modify: `tests/spec/command_spec.lua`

- [ ] **Step 1: Append the failing tests**

```lua
-- (appended to tests/spec/command_spec.lua)
describe("persistent_term.command.cmd_kill", function()
  before_each(function()
    package.loaded["persistent_term.command"] = nil
    package.loaded["persistent_term.bridge"] = nil
  end)

  it("refuses outside a pterm:// buffer", function()
    local cmd = require("persistent_term.command")
    local ok, err = cmd.cmd_kill(vim.api.nvim_create_buf(true, true))
    assert.is_false(ok)
    assert.is_truthy(err:match("not a persistent-term buffer"))
  end)

  it("kills pane and wipes buffer when invoked from a pterm:// buffer", function()
    local killed_pane = nil
    package.loaded["persistent_term.bridge"] = {
      kill = function(handle)
        killed_pane = handle.pane_id
        if vim.api.nvim_buf_is_valid(handle.bufnr) then
          vim.api.nvim_buf_delete(handle.bufnr, { force = true })
        end
      end,
    }
    local bufnr = vim.api.nvim_create_buf(true, true)
    vim.api.nvim_buf_set_name(bufnr, "pterm://dev")
    vim.b[bufnr].persistent_term_name = "dev"
    vim.b[bufnr].persistent_term_pane_id = "%77"

    local cmd = require("persistent_term.command")
    local ok, err = cmd.cmd_kill(bufnr)
    assert.is_true(ok)
    assert.is_nil(err)
    assert.equals("%77", killed_pane)
    assert.is_false(vim.api.nvim_buf_is_valid(bufnr))
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/spec/command_spec.lua {minimal_init='tests/minimal_init.lua'}"`
Expected: `cmd_kill` undefined.

- [ ] **Step 3: Implement `cmd_kill`**

Append to `command.lua`:

```lua
function M.cmd_kill(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local name = vim.api.nvim_buf_get_name(bufnr)
  if not name:match("^pterm://") then
    return false, "not a persistent-term buffer"
  end
  local pane_id = vim.b[bufnr].persistent_term_pane_id
  local handle = {
    bufnr = bufnr,
    pane_id = pane_id,
    name = vim.b[bufnr].persistent_term_name,
  }
  local bridge = require("persistent_term.bridge")
  bridge.kill(handle)
  return true
end
```

- [ ] **Step 4: Run test to verify it passes**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/spec/command_spec.lua {minimal_init='tests/minimal_init.lua'}"`
Expected: all command tests pass.

- [ ] **Step 5: Commit**

```bash
git add lua/persistent_term/command.lua tests/spec/command_spec.lua
git commit -m "feat(lua): :PTermKill destroys pane and wipes buffer"
```

---

## Task 18: Lua — `install.lua` and `:PTermInstall`

**Files:**
- Create: `lua/persistent_term/install.lua`
- Create: `tests/spec/install_spec.lua`

- [ ] **Step 1: Write the failing tests**

```lua
-- tests/spec/install_spec.lua
describe("persistent_term.install", function()
  local install
  local tmpdir

  before_each(function()
    package.loaded["persistent_term.install"] = nil
    tmpdir = vim.fn.tempname()
    vim.fn.mkdir(tmpdir, "p")
    -- Force the install dir to point at our tmp dir.
    vim.env.PERSISTENT_TERM_INSTALL_DIR = tmpdir
    install = require("persistent_term.install")
  end)

  after_each(function()
    vim.fn.delete(tmpdir, "rf")
    vim.env.PERSISTENT_TERM_INSTALL_DIR = nil
  end)

  it("binary_path uses the override", function()
    assert.equals(tmpdir .. "/persistent-term-pipe", install.binary_path())
  end)

  it("is_installed returns false when the file is missing", function()
    assert.is_false(install.is_installed())
  end)

  it("is_installed returns true when file exists and is executable", function()
    local path = install.binary_path()
    vim.fn.writefile({ "#!/bin/sh", "exit 0" }, path)
    vim.fn.system({ "chmod", "0755", path })
    assert.is_true(install.is_installed())
  end)

  it("verify_sha256 returns true when hash matches", function()
    local path = tmpdir .. "/payload.bin"
    vim.fn.writefile({ "hello world" }, path, "b")
    local expected = vim.fn.sha256(table.concat(vim.fn.readfile(path, "b"), "\n"))
    assert.is_true(install.verify_sha256(path, expected))
  end)

  it("verify_sha256 returns false on mismatch", function()
    local path = tmpdir .. "/payload.bin"
    vim.fn.writefile({ "hello world" }, path, "b")
    assert.is_false(install.verify_sha256(path, string.rep("0", 64)))
  end)

  it("install_from_local copies+chmods+verifies", function()
    local src = tmpdir .. "/src"
    vim.fn.writefile({ "#!/bin/sh", "echo ok" }, src)
    local sha = vim.fn.sha256(table.concat(vim.fn.readfile(src, "b"), "\n"))
    local ok, err = install.install_from_local(src, sha)
    assert.is_true(ok, err)
    assert.is_true(install.is_installed())
  end)

  it("install_from_local refuses when hash does not match", function()
    local src = tmpdir .. "/src"
    vim.fn.writefile({ "garbage" }, src)
    local ok, err = install.install_from_local(src, string.rep("0", 64))
    assert.is_false(ok)
    assert.is_truthy(err:match("sha256 mismatch"))
  end)
end)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/spec/install_spec.lua {minimal_init='tests/minimal_init.lua'}"`
Expected: module not found.

- [ ] **Step 3: Implement `install.lua`**

```lua
-- lua/persistent_term/install.lua
local M = {}

local PINNED_VERSION = "v0.1.0"
local REPO = "hbinhng/persistent-term.nvim"

local function detect_os()
  local sys = vim.uv and vim.uv.os_uname() or vim.loop.os_uname()
  local lower = sys.sysname:lower()
  if lower:match("linux") then return "linux" end
  if lower:match("darwin") then return "darwin" end
  error("unsupported OS: " .. sys.sysname)
end

local function detect_arch()
  local sys = vim.uv and vim.uv.os_uname() or vim.loop.os_uname()
  local m = sys.machine
  if m == "x86_64" or m == "amd64" then return "amd64" end
  if m == "aarch64" or m == "arm64" then return "arm64" end
  error("unsupported arch: " .. m)
end

local function install_dir()
  if vim.env.PERSISTENT_TERM_INSTALL_DIR and vim.env.PERSISTENT_TERM_INSTALL_DIR ~= "" then
    return vim.env.PERSISTENT_TERM_INSTALL_DIR
  end
  local dir = vim.fn.stdpath("data") .. "/persistent-term/bin"
  vim.fn.mkdir(dir, "p")
  return dir
end

function M.binary_path()
  return install_dir() .. "/persistent-term-pipe"
end

function M.is_installed()
  local path = M.binary_path()
  if vim.fn.filereadable(path) ~= 1 then return false end
  if vim.fn.executable(path) ~= 1 then return false end
  return true
end

function M.verify_sha256(path, expected_hex)
  if vim.fn.filereadable(path) ~= 1 then return false end
  local bytes = table.concat(vim.fn.readfile(path, "b"), "\n")
  return vim.fn.sha256(bytes) == expected_hex
end

local function asset_name()
  return string.format("persistent-term-pipe-%s-%s", detect_os(), detect_arch())
end

local function release_url(suffix)
  return string.format(
    "https://github.com/%s/releases/download/%s/%s%s",
    REPO, PINNED_VERSION, asset_name(), suffix or ""
  )
end

function M.install_from_local(src_path, expected_sha256)
  if not M.verify_sha256(src_path, expected_sha256) then
    return false, "sha256 mismatch for " .. src_path
  end
  local dst = M.binary_path()
  local bytes = table.concat(vim.fn.readfile(src_path, "b"), "\n")
  vim.fn.writefile(vim.split(bytes, "\n", { plain = true }), dst, "b")
  vim.fn.system({ "chmod", "0755", dst })
  return true
end

local function download(url, dst)
  local res = vim.system({ "curl", "-fsSL", "-o", dst, url }, { text = true }):wait()
  if res.code ~= 0 then
    return false, "curl failed: " .. (res.stderr or "")
  end
  return true
end

function M.run_install()
  local log = require("persistent_term.log")
  local tmp_bin = vim.fn.tempname() .. "-pipe"
  local tmp_sha = tmp_bin .. ".sha256"
  local ok, err = download(release_url(""), tmp_bin)
  if not ok then return false, err end
  ok, err = download(release_url(".sha256"), tmp_sha)
  if not ok then return false, err end
  local sha_line = (vim.fn.readfile(tmp_sha)[1] or ""):lower()
  local sha = sha_line:match("^([a-f0-9]+)") or sha_line
  if #sha ~= 64 then
    return false, "invalid sha256 file contents"
  end
  ok, err = M.install_from_local(tmp_bin, sha)
  if not ok then return false, err end
  log.warn("persistent-term-pipe installed at " .. M.binary_path())
  return true
end

return M
```

- [ ] **Step 4: Run test to verify it passes**

Run: `nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/spec/install_spec.lua {minimal_init='tests/minimal_init.lua'}"`
Expected: all install tests pass.

- [ ] **Step 5: Commit**

```bash
git add lua/persistent_term/install.lua tests/spec/install_spec.lua
git commit -m "feat(lua): install module with sha256 verify and local-copy install"
```

---

## Task 19: Lua — public API + command registrations + Makefile lua-test target

**Files:**
- Create: `lua/persistent_term/init.lua`
- Create: `plugin/persistent_term.lua`
- Modify: `Makefile`

- [ ] **Step 1: Write `lua/persistent_term/init.lua`**

```lua
-- lua/persistent_term/init.lua
local M = {}

function M.open(raw)
  local handle, err = require("persistent_term.command").cmd_open(raw)
  if err then
    require("persistent_term.log").error(err)
    return nil
  end
  if handle and vim.api.nvim_buf_is_valid(handle.bufnr) then
    vim.cmd.buffer(handle.bufnr)
  end
  return handle
end

function M.attach(target)
  local handle, err = require("persistent_term.command").cmd_attach(target)
  if err then
    require("persistent_term.log").error(err)
    return nil
  end
  if handle and vim.api.nvim_buf_is_valid(handle.bufnr) then
    vim.cmd.buffer(handle.bufnr)
  end
  return handle
end

function M.kill()
  local ok, err = require("persistent_term.command").cmd_kill()
  if not ok then
    require("persistent_term.log").error(err)
  end
end

function M.install()
  local ok, err = require("persistent_term.install").run_install()
  if not ok then
    require("persistent_term.log").error(err)
  end
end

function M.complete_attach(arg_lead, cmd_line, cursor_pos)
  return require("persistent_term.command").complete_attach(arg_lead, cmd_line, cursor_pos)
end

return M
```

- [ ] **Step 2: Write `plugin/persistent_term.lua`**

```lua
-- plugin/persistent_term.lua
if vim.g.loaded_persistent_term == 1 then
  return
end
vim.g.loaded_persistent_term = 1

local function lazy(fn_name)
  return function(opts)
    require("persistent_term")[fn_name](opts.args)
  end
end

vim.api.nvim_create_user_command("PTerm", lazy("open"), {
  nargs = "+",
  desc = "Open a persistent terminal: :PTerm {name} -- {cmd...}",
})

vim.api.nvim_create_user_command("PTermAttach", lazy("attach"), {
  nargs = 1,
  desc = "Attach a buffer to an existing persistent-term pane",
  complete = function(arg_lead, cmd_line, cursor_pos)
    return require("persistent_term").complete_attach(arg_lead, cmd_line, cursor_pos)
  end,
})

vim.api.nvim_create_user_command("PTermKill", function(_)
  require("persistent_term").kill()
end, {
  desc = "Kill the current persistent-term buffer's pane",
})

vim.api.nvim_create_user_command("PTermInstall", function(_)
  require("persistent_term").install()
end, {
  desc = "Download persistent-term-pipe helper binary",
})
```

- [ ] **Step 3: Add `lua-test` and `lua-lint` targets to the Makefile**

Replace the `Makefile` body with:

```make
.PHONY: build test lint clean deps go-build go-test go-lint lua-test lua-lint

ROOT := $(shell pwd)
GO_BIN := $(ROOT)/go/bin/persistent-term-pipe
NVIM ?= nvim

deps:
	./tests/setup.sh

clean:
	rm -rf go/bin dist .deps

go-build:
	mkdir -p go/bin
	cd go && go build -o bin/persistent-term-pipe .

go-test:
	cd go && go test ./...

go-lint:
	cd go && go vet ./...
	cd go && gofmt -l . | (! grep .)

lua-test: deps
	$(NVIM) --headless -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests/spec/ {minimal_init='tests/minimal_init.lua'}"

lua-lint:
	luacheck lua/ tests/
	stylua --check lua/ tests/

build: go-build

test: go-build go-test lua-test

lint: go-lint lua-lint
```

- [ ] **Step 4: Smoke-test the registrations**

Run: `nvim --headless -u tests/minimal_init.lua -c "runtime plugin/persistent_term.lua" -c "lua local t={} for _,n in ipairs({'PTerm','PTermAttach','PTermKill','PTermInstall'}) do table.insert(t, vim.fn.exists(':' .. n)) end print(vim.inspect(t))" -c "quit"`
Expected: prints `{ 2, 2, 2, 2 }` (all commands defined).

Run: `make lua-test`
Expected: every Lua spec file passes.

- [ ] **Step 5: Commit**

```bash
git add lua/persistent_term/init.lua plugin/persistent_term.lua Makefile
git commit -m "feat(lua): public API + ex-command registrations + lua test target"
```

---

## Task 20: Integration tests against real tmux

**Files:**
- Create: `tests/spec/integration_spec.lua`

- [ ] **Step 1: Write the integration suite**

```lua
-- tests/spec/integration_spec.lua
local has_tmux = (vim.fn.executable("tmux") == 1)

if not has_tmux then
  describe("persistent-term integration", function()
    pending("requires tmux on PATH")
  end)
  return
end

local function run(argv)
  return vim.system(argv, { text = true }):wait()
end

local function reset_tmux_server()
  run({ "tmux", "-L", "persistent-term", "kill-server" })
end

local function install_local_binary()
  local root = vim.fn.fnamemodify(vim.fn.resolve(debug.getinfo(1).source:sub(2)), ":h:h:h")
  local src = root .. "/go/bin/persistent-term-pipe"
  assert(vim.fn.filereadable(src) == 1, "build the helper first (make build)")
  local dst_dir = vim.fn.tempname()
  vim.fn.mkdir(dst_dir, "p")
  vim.env.PERSISTENT_TERM_INSTALL_DIR = dst_dir
  local bytes = table.concat(vim.fn.readfile(src, "b"), "\n")
  vim.fn.writefile(vim.split(bytes, "\n", { plain = true }), dst_dir .. "/persistent-term-pipe", "b")
  vim.fn.system({ "chmod", "0755", dst_dir .. "/persistent-term-pipe" })
end

local function wait_until(predicate, ms)
  return vim.wait(ms or 2000, predicate, 20)
end

describe("persistent-term integration", function()
  before_each(function()
    reset_tmux_server()
    install_local_binary()
    for _, mod in ipairs({
      "persistent_term", "persistent_term.command", "persistent_term.bridge",
      "persistent_term.tmux", "persistent_term.install",
    }) do
      package.loaded[mod] = nil
    end
    vim.cmd("runtime plugin/persistent_term.lua")
  end)

  after_each(function()
    reset_tmux_server()
  end)

  it("PTerm starts a pane and pipes output into the buffer", function()
    vim.cmd([[PTerm dev -- bash -c 'printf hello; sleep 30']])
    local bufnr = vim.api.nvim_get_current_buf()
    assert.is_truthy(wait_until(function()
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      for _, l in ipairs(lines) do
        if l:find("hello", 1, true) then return true end
      end
      return false
    end, 5000))
  end)

  it("PTermAttach after :bd replays scrollback", function()
    vim.cmd([[PTerm rep -- bash -c 'echo replay-line; sleep 30']])
    local bufnr = vim.api.nvim_get_current_buf()
    assert.is_truthy(wait_until(function()
      local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      for _, l in ipairs(lines) do if l:find("replay-line", 1, true) then return true end end
      return false
    end, 5000))
    vim.cmd("bdelete!")
    vim.cmd("PTermAttach rep")
    local bufnr2 = vim.api.nvim_get_current_buf()
    assert.is_truthy(wait_until(function()
      local lines = vim.api.nvim_buf_get_lines(bufnr2, 0, -1, false)
      for _, l in ipairs(lines) do if l:find("replay-line", 1, true) then return true end end
      return false
    end, 5000))
  end)

  it("duplicate-name :PTerm fails", function()
    vim.cmd([[PTerm dup -- bash -c 'sleep 30']])
    local result = pcall(vim.cmd, [[PTerm dup -- bash -c 'sleep 30']])
    -- The command always succeeds at the vim level but emits a notify.
    -- Check via list-panes that there is only one matching pane.
    local res = run({ "tmux", "-L", "persistent-term", "list-panes", "-aF", "#{@pterm_name}" })
    local count = 0
    for line in (res.stdout or ""):gmatch("[^\n]+") do
      if line == "dup" then count = count + 1 end
    end
    assert.equals(1, count)
  end)

  it("PTermKill removes the pane", function()
    vim.cmd([[PTerm kx -- bash -c 'sleep 30']])
    vim.cmd("PTermKill")
    assert.is_truthy(wait_until(function()
      local res = run({ "tmux", "-L", "persistent-term", "list-panes", "-aF", "#{@pterm_name}" })
      return not (res.stdout or ""):find("kx", 1, true)
    end, 3000))
  end)

  it("resize forwards to tmux", function()
    vim.cmd([[PTerm rz -- bash -c 'sleep 30']])
    -- Force a window size and let the debounce window pass.
    vim.cmd("vertical resize 60")
    vim.wait(200)
    local res = run({ "tmux", "-L", "persistent-term", "display-message", "-p", "-t",
      vim.b.persistent_term_pane_id, "#{pane_width}" })
    assert.equals("60", vim.trim(res.stdout))
  end)
end)
```

- [ ] **Step 2: Run the integration suite**

Run: `make build && nvim --headless -u tests/minimal_init.lua -c "PlenaryBustedDirectory tests/spec/integration_spec.lua {minimal_init='tests/minimal_init.lua'}"`
Expected: all integration tests pass (or pending if tmux is absent).

- [ ] **Step 3: Commit**

```bash
git add tests/spec/integration_spec.lua
git commit -m "test: end-to-end integration against real tmux"
```

---

## Task 21: CI workflow

**Files:**
- Create: `.github/workflows/ci.yml`

- [ ] **Step 1: Write the workflow**

```yaml
# .github/workflows/ci.yml
name: ci

on:
  push:
    branches: [main]
  pull_request:

jobs:
  lint:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with:
          go-version: "1.22"
      - name: Install Lua linters
        run: |
          sudo apt-get update
          sudo apt-get install -y luarocks
          sudo luarocks install luacheck
          curl -sSL https://github.com/JohnnyMorganz/StyLua/releases/latest/download/stylua-linux-x86_64.zip -o /tmp/stylua.zip
          (cd /tmp && unzip -o stylua.zip && sudo install -m 0755 stylua /usr/local/bin/stylua)
      - name: Lint
        run: make lint

  test:
    needs: lint
    strategy:
      fail-fast: false
      matrix:
        os: [ubuntu-latest, macos-latest]
        nvim: [v0.10.0, stable, nightly]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with:
          go-version: "1.22"
      - name: Install tmux (Linux)
        if: runner.os == 'Linux'
        run: sudo apt-get update && sudo apt-get install -y tmux
      - name: Install tmux (macOS)
        if: runner.os == 'macOS'
        run: brew install tmux
      - uses: rhysd/action-setup-vim@v1
        with:
          neovim: true
          version: ${{ matrix.nvim }}
      - name: Build helper
        run: make build
      - name: Test
        run: make test
```

- [ ] **Step 2: Validate locally**

Run: `make build && make test && make lint`
Expected: everything green.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: lint + test matrix (Linux/macOS × nvim 0.10/stable/nightly)"
```

---

## Task 22: Release workflow

**Files:**
- Create: `.github/workflows/release.yml`
- Modify: `Makefile`

- [ ] **Step 1: Add `release` target to the Makefile**

Append:

```make
.PHONY: release

release:
	mkdir -p dist
	@for combo in linux/amd64 linux/arm64 darwin/amd64 darwin/arm64; do \
		os=$${combo%/*}; arch=$${combo#*/}; \
		out="dist/persistent-term-pipe-$$os-$$arch"; \
		echo "building $$out"; \
		(cd go && GOOS=$$os GOARCH=$$arch CGO_ENABLED=0 go build -trimpath -o ../$$out .); \
		sha256sum $$out | awk '{print $$1}' > $$out.sha256; \
	done
	@ls -la dist/
```

(On macOS, `sha256sum` is `shasum -a 256`. The workflow runs on `ubuntu-latest` where `sha256sum` is available.)

- [ ] **Step 2: Write the workflow**

```yaml
# .github/workflows/release.yml
name: release

on:
  push:
    tags:
      - "v*"

jobs:
  build-and-publish:
    runs-on: ubuntu-latest
    permissions:
      contents: write
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-go@v5
        with:
          go-version: "1.22"
      - name: Build matrix
        run: make release
      - name: Upload artifacts to release
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          gh release create "$GITHUB_REF_NAME" --title "$GITHUB_REF_NAME" --notes-file /dev/null || true
          gh release upload "$GITHUB_REF_NAME" dist/* --clobber
```

- [ ] **Step 3: Verify `make release` locally**

Run: `make release && ls dist/`
Expected: eight files (`persistent-term-pipe-*-{amd64,arm64}` and matching `.sha256`).

Run: `file dist/persistent-term-pipe-linux-amd64`
Expected: `ELF 64-bit ... x86-64`.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/release.yml Makefile
git commit -m "build: cross-compile release matrix and GitHub Release upload"
```

---

## Task 23: README

**Files:**
- Create: `README.md`

- [ ] **Step 1: Write the README**

```markdown
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
```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs: README with install, usage, and dev instructions"
```

---

## Self-Review

(Run by the plan author; if you discover gaps while implementing, raise them with the user before patching the plan.)

**Spec coverage check:**

| Spec section                                  | Task(s)                |
|-----------------------------------------------|------------------------|
| §3 Architecture                               | Tasks 5, 10–13         |
| §4.1 Commands                                 | Tasks 14–18, 19        |
| §4.2 `:PTerm` (argv parsing, sanitization)    | Tasks 14, 15           |
| §4.3 `:PTermAttach` (resolve + replay)        | Task 16                |
| §4.4 `:PTermKill`                             | Task 17                |
| §4.5 `:PTermInstall`                          | Task 18                |
| §4.6 Tab completion                           | Tasks 16, 19           |
| §4.7 Buffer behavior                          | Tasks 11, 13           |
| §5.1 Socket handshake                         | Tasks 3, 10            |
| §5.2 Raw byte transport                       | Tasks 4, 11            |
| §5.3 Backpressure                             | Task 11                |
| §5.4 Resize                                   | Task 12                |
| §5.5 Shutdown paths                           | Tasks 11, 13           |
| §6 Persistence (tmux source of truth)         | Tasks 8, 9, 15, 16     |
| §7 Lifecycle flows                            | Tasks 15, 16, 17       |
| §8.1 Pre-flight                               | Tasks 9, 15, 16        |
| §8.2/8.3 Error handling                       | Tasks 11, 13, 15, 16   |
| §8.4 Logging                                  | Task 7                 |
| §9 Security (no-shell, sanitize, sockets)     | Tasks 2, 8, 14, 15     |
| §10 Repo layout                               | Tasks 1, 7–19          |
| §11 Tests                                     | Tasks 2–18, 20         |
| §12 Build & distribution                      | Tasks 6, 19, 21, 22    |
| §13 Minimum versions                          | Task 9 (tmux), Task 21 (matrix), README |
| §14 Open follow-ups                           | (not in scope; deferred) |

No spec requirement is unaccounted for.

**Placeholder scan:** No "TBD", "TODO", or "implement later" left in plan steps.

**Type consistency:** Pane id format is `%[0-9]+` across builders, parsers, completion, and tests. The handle table keys (`bufnr`, `chan`, `name`, `pane_id`, `session_id`, `window_id`, `_on_input_holder`, `_server`, `_attached`, `_pending_writes`, `_closing`, `_on_detach`, `_resize_timer`, `_pending_size`) are stable across all tasks that touch them.

---
