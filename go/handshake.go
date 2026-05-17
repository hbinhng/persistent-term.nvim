package main

import (
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
	const maxReplyLen = 256
	var lineBuf []byte
	oneByte := make([]byte, 1)
	for {
		if _, err := conn.Read(oneByte); err != nil {
			conn.Close()
			return nil, fmt.Errorf("read auth reply: %w", err)
		}
		if oneByte[0] == '\n' {
			break
		}
		lineBuf = append(lineBuf, oneByte[0])
		if len(lineBuf) >= maxReplyLen {
			conn.Close()
			return nil, errors.New("auth reply too long")
		}
	}
	line := string(lineBuf)
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
