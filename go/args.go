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
	a.SocketPath = filepath.Clean(a.SocketPath)
	if !filepath.IsAbs(a.SocketPath) || !isSafeSocketPath(a.SocketPath) {
		return Args{}, errUnsafeSocketPath
	}
	return a, nil
}

func isSafeSocketPath(p string) bool {
	safe := []string{"/run/user/", "/tmp/"}
	if xdg := os.Getenv("XDG_RUNTIME_DIR"); xdg != "" {
		if trimmed := strings.TrimRight(xdg, "/"); trimmed != "" {
			safe = append(safe, trimmed+"/")
		}
	}
	for _, prefix := range safe {
		if strings.HasPrefix(p, prefix) {
			return true
		}
	}
	return false
}
