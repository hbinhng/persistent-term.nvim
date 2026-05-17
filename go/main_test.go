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
