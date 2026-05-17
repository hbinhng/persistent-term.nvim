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
// using a TCP loopback pair (for OS-level buffering) and io.Pipe.
type proxyHarness struct {
	socket     net.Conn
	socketPeer net.Conn
	stdin      *io.PipeReader
	stdinWrite *io.PipeWriter
	stdout     *io.PipeReader
	stdoutW    *io.PipeWriter
}

func newProxyHarness() *proxyHarness {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		panic(err)
	}
	connCh := make(chan net.Conn, 1)
	go func() {
		c, err := ln.Accept()
		if err != nil {
			panic(err)
		}
		ln.Close()
		connCh <- c
	}()
	socket, err := net.Dial("tcp", ln.Addr().String())
	if err != nil {
		panic(err)
	}
	peer := <-connCh
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
	go func() { h.socketPeer.Write(payload) }()

	wg.Wait()
	h.socketPeer.Close()
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
