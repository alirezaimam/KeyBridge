package control

/*
#include <sys/types.h>
#include <unistd.h>
#include <sys/socket.h>
static int root_peer(int fd) { uid_t u; gid_t g; return getpeereid(fd,&u,&g)==0 && u==0; }
*/
import "C"
import (
	"errors"
	"net"
)

func verifyPeer(c net.Conn) error {
	u, ok := c.(*net.UnixConn)
	if !ok {
		return errors.New("not a local socket")
	}
	raw, e := u.SyscallConn()
	if e != nil {
		return e
	}
	valid := false
	e = raw.Control(func(fd uintptr) { valid = C.root_peer(C.int(fd)) != 0 })
	if e != nil {
		return e
	}
	if !valid {
		return errors.New("helper is not owned by root")
	}
	return nil
}
