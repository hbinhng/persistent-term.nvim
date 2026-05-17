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
