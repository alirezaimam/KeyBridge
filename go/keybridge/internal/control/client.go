// Package control connects KeyBridge to its local privileged HID helper.
package control

import (
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"time"
)

const SocketPath = "/var/run/local.clipboardhid/control.sock"

type Settings struct {
	MaxLength  uint32
	KeyDownMS  uint32
	KeyUpMS    uint32
	InterKeyMS uint32
	StartDelayMS uint32
}

type Status byte

const (
	Ready            Status = 'R'
	Done             Status = 'D'
	Cancelled        Status = 'C'
	HIDFailed        Status = 'E'
	Busy             Status = 'B'
	HIDUnavailable   Status = 'H'
	RejectedByHelper Status = 'P'
)

// Session is one authenticated connection to the privileged helper.
// It is intentionally single-flight: one connection may type one clipboard snapshot
// at a time, which matches the helper's exclusive virtual-keyboard lock.
type Session struct {
	conn    net.Conn
	limit   uint32
	replies chan result
	lost    chan struct{}
}

func (s Settings) Valid() bool {
	return s.MaxLength >= 1 && s.MaxLength <= 1_048_576 &&
		s.KeyDownMS >= 1 && s.KeyDownMS <= 60_000 &&
		s.KeyUpMS >= 1 && s.KeyUpMS <= 60_000 &&
		s.InterKeyMS <= 60_000 && s.StartDelayMS <= 60_000
}

func (s Settings) wire() []byte {
	values := [...]uint32{s.MaxLength, s.KeyDownMS, s.KeyUpMS, s.InterKeyMS}
	out := make([]byte, len(values)*4)
	for i, value := range values {
		out[i*4] = byte(value)
		out[i*4+1] = byte(value >> 8)
		out[i*4+2] = byte(value >> 16)
		out[i*4+3] = byte(value >> 24)
	}
	return out
}

// ValidateText accepts exactly the initial KeyBridge profile: printable US-ASCII
// without tab, line endings, or control characters.
func ValidateText(text string, maxLength uint32) error {
	if len(text) == 0 {
		return errors.New("clipboard is empty")
	}
	if uint64(len(text)) > uint64(maxLength) {
		return errors.New("clipboard exceeds maximum length")
	}
	for _, c := range []byte(text) {
		if c < 0x20 || c > 0x7e {
			return errors.New("clipboard must contain printable US-ASCII text on one line")
		}
	}
	return nil
}

// Connect performs the fixed-size settings handshake. The returned connection is
// retained while typing; closing it tells the helper to cancel and release HID keys.
func Connect(s Settings, timeout time.Duration) (*Session, Status, error) {
	if !s.Valid() {
		return nil, 0, errors.New("invalid KeyBridge settings")
	}
	conn, err := net.DialTimeout("unix", SocketPath, timeout)
	if err != nil {
		return nil, 0, fmt.Errorf("connect to HID helper: %w", err)
	}
	if err := verifyPeer(conn); err != nil {
		conn.Close()
		return nil, 0, err
	}
	conn.SetDeadline(time.Now().Add(timeout))
	if _, err := conn.Write(s.wire()); err != nil {
		conn.Close()
		return nil, 0, fmt.Errorf("send settings to HID helper: %w", err)
	}
	if err := conn.SetReadDeadline(time.Now().Add(timeout)); err != nil {
		conn.Close()
		return nil, 0, fmt.Errorf("set helper deadline: %w", err)
	}
	var reply [1]byte
	if _, err := io.ReadFull(conn, reply[:]); err != nil {
		conn.Close()
		return nil, 0, fmt.Errorf("read helper status: %w", err)
	}
	_ = conn.SetDeadline(time.Time{})
	status := Status(reply[0])
	if status != Ready {
		conn.Close()
		return nil, status, nil
	}
	session := &Session{conn: conn, limit: s.MaxLength, replies: make(chan result, 1), lost: make(chan struct{})}
	go session.readReplies()
	return session, status, nil
}

// Type sends a previously validated clipboard snapshot and waits for its final state.
func (s *Session) Type(text []byte) (Status, error) {
	if err := ValidateText(string(text), s.limit); err != nil {
		return 0, err
	}
	if _, err := s.conn.Write([]byte{'T'}); err != nil {
		return 0, fmt.Errorf("start typing: %w", err)
	}
	var size [4]byte
	binary.LittleEndian.PutUint32(size[:], uint32(len(text)))
	if _, err := s.conn.Write(size[:]); err != nil {
		return 0, fmt.Errorf("send clipboard length: %w", err)
	}
	if _, err := s.conn.Write(text); err != nil {
		return 0, fmt.Errorf("send clipboard text: %w", err)
	}
	r, ok := <-s.replies
	if !ok {
		return 0, io.EOF
	}
	return r.status, r.err
}

func (s *Session) Cancel() error {
	_, err := s.conn.Write([]byte{'C'})
	return err
}

func (s *Session) Close() error { return s.conn.Close() }

type result struct {
	status Status
	err    error
}

func (s *Session) readReplies() {
	defer close(s.lost)
	defer close(s.replies)
	for {
		var b [1]byte
		_, e := io.ReadFull(s.conn, b[:])
		if e != nil {
			return
		}
		select {
		case s.replies <- result{Status(b[0]), nil}:
		default:
			s.conn.Close()
			return
		}
	}
}
func (s *Session) Disconnected() bool {
	select {
	case <-s.lost:
		return true
	default:
		return false
	}
}
