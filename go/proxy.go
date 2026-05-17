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
		wg       sync.WaitGroup
		mu       sync.Mutex
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

	// Wrap stdin in an io.Pipe so the conn->stdout goroutine can cancel the
	// stdin->conn goroutine by closing the write end of the pipe. The
	// fire-and-forget goroutine below drains real stdin into the pipe; it may
	// outlive runProxy but that is fine — the process exits after main returns.
	stdinPR, stdinPW := io.Pipe()
	go func() {
		buf := make([]byte, copyBufferSize)
		_, err := io.CopyBuffer(stdinPW, stdin, buf)
		if err != nil {
			stdinPW.CloseWithError(err)
		} else {
			stdinPW.Close()
		}
	}()

	// stdin -> conn
	wg.Add(1)
	go func() {
		defer wg.Done()
		buf := make([]byte, copyBufferSize)
		_, err := io.CopyBuffer(conn, stdinPR, buf)
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
		// Cancel the stdin->conn goroutine: closing stdinPW makes stdinPR.Read
		// return an error, which unblocks io.CopyBuffer(conn, stdinPR, buf).
		stdinPW.Close()
		// Close the connection so the stdin->conn goroutine's pending Write
		// also fails if it's mid-write.
		conn.Close()
		// Closing stdout will unblock any pending writer on the other side.
		if cw, ok := stdout.(io.Closer); ok {
			cw.Close()
		}
	}()

	wg.Wait()
	return firstErr
}
