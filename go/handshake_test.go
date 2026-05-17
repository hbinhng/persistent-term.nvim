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
