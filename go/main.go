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
