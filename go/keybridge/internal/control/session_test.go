package control

import (
	"encoding/binary"
	"io"
	"net"
	"testing"
	"time"
)

func testSession(c net.Conn) *Session {
	s := &Session{conn: c, limit: 256, replies: make(chan result, 1), lost: make(chan struct{})}
	go s.readReplies()
	return s
}
func TestTypeFrameAndCompletion(t *testing.T) {
	a, b := net.Pipe()
	defer b.Close()
	s := testSession(a)
	defer s.Close()
	errCh := make(chan error, 1)
	go func() {
		var header [5]byte
		_, e := io.ReadFull(b, header[:])
		if e != nil {
			errCh <- e
			return
		}
		if header[0] != 'T' || binary.LittleEndian.Uint32(header[1:]) != 3 {
			errCh <- io.ErrUnexpectedEOF
			return
		}
		var data [3]byte
		_, e = io.ReadFull(b, data[:])
		if string(data[:]) != "A! " {
			e = io.ErrUnexpectedEOF
		}
		errCh <- e
		b.Write([]byte{'D'})
	}()
	st, e := s.Type([]byte("A! "))
	if e != nil || st != Done {
		t.Fatalf("result %v %v", st, e)
	}
	if e = <-errCh; e != nil {
		t.Fatal(e)
	}
}
func TestIdleDisconnect(t *testing.T) {
	a, b := net.Pipe()
	s := testSession(a)
	defer s.Close()
	b.Close()
	select {
	case <-s.lost:
	case <-time.After(time.Second):
		t.Fatal("disconnect not detected")
	}
}
func TestCloseUnblocksTyping(t *testing.T) {
	a, b := net.Pipe()
	defer b.Close()
	s := testSession(a)
	done := make(chan error, 1)
	go func() { _, e := s.Type([]byte("abc")); done <- e }()
	header := make([]byte, 8)
	io.ReadFull(b, header)
	s.Close()
	select {
	case e := <-done:
		if e == nil {
			t.Fatal("expected disconnect")
		}
	case <-time.After(time.Second):
		t.Fatal("cancel blocked")
	}
}
