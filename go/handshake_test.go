package main

import (
	"bufio"
	"net"
	"strings"
	"testing"
	"time"
)

// listen returns a Unix socket listener at sockPath. Establish this BEFORE
// launching the handshake goroutine to avoid a connect-before-listen race.
func listen(t *testing.T, sockPath string) net.Listener {
	t.Helper()
	ln, err := net.Listen("unix", sockPath)
	if err != nil {
		t.Fatalf("listen: %v", err)
	}
	t.Cleanup(func() { ln.Close() })
	return ln
}

// acceptOne accepts one connection on ln and returns it along with the
// first newline-terminated line it received.
func acceptOne(t *testing.T, ln net.Listener) (net.Conn, string) {
	t.Helper()
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
	ln := listen(t, sockPath)
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

	srvConn, line := acceptOne(t, ln)
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
	ln := listen(t, sockPath)
	done := make(chan error, 1)
	go func() {
		_, err := handshake(sockPath, "BADTOKEN", time.Second)
		done <- err
	}()

	srvConn, _ := acceptOne(t, ln)
	if _, err := srvConn.Write([]byte("ERR auth\n")); err != nil {
		t.Fatalf("write: %v", err)
	}
	srvConn.Close()

	err := <-done
	if err == nil || !strings.Contains(err.Error(), "auth") {
		t.Errorf("expected auth error, got %v", err)
	}
}

func TestHandshakeServerNeverReplies(t *testing.T) {
	sockPath := tempSock(t)
	ln := listen(t, sockPath)
	done := make(chan error, 1)
	go func() {
		_, err := handshake(sockPath, "X", 200*time.Millisecond)
		done <- err
	}()

	srvConn, _ := acceptOne(t, ln)
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

func TestHandshakeDoesNotConsumeBytesAfterOK(t *testing.T) {
	sockPath := tempSock(t)
	ln := listen(t, sockPath)
	done := make(chan struct {
		conn net.Conn
		err  error
	}, 1)
	go func() {
		conn, err := handshake(sockPath, "TOK", time.Second)
		done <- struct {
			conn net.Conn
			err  error
		}{conn, err}
	}()

	srvConn, _ := acceptOne(t, ln)
	// Send OK\n and EXTRA\n in a single Write to maximize the chance
	// the kernel delivers them together to the helper.
	if _, err := srvConn.Write([]byte("OK\nEXTRA\n")); err != nil {
		t.Fatalf("write: %v", err)
	}

	res := <-done
	if res.err != nil {
		t.Fatalf("handshake err: %v", res.err)
	}
	defer res.conn.Close()

	// We must still be able to read "EXTRA\n" from the returned conn,
	// i.e. handshake must not have consumed those bytes into a discarded buffer.
	res.conn.SetReadDeadline(time.Now().Add(time.Second))
	buf := make([]byte, 6)
	n, err := res.conn.Read(buf)
	if err != nil {
		t.Fatalf("post-handshake read: %v", err)
	}
	if string(buf[:n]) != "EXTRA\n" {
		t.Errorf("post-handshake conn read = %q, want \"EXTRA\\n\"", string(buf[:n]))
	}
	srvConn.Close()
}

func tempSock(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	return dir + "/test.sock"
}
