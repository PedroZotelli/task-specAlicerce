//go:build windows

package mesh

import (
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"syscall"
)

// SetProcessGroup starts the command in a new process group, the Windows
// counterpart of a POSIX process group leader.
func SetProcessGroup(command *exec.Cmd) {
	command.SysProcAttr = &syscall.SysProcAttr{CreationFlags: syscall.CREATE_NEW_PROCESS_GROUP}
}

// TerminateProcessGroup stops the command and every child it spawned. Windows
// has no group signal, so taskkill walks the process tree.
func TerminateProcessGroup(command *exec.Cmd) error {
	return exec.Command("taskkill", "/T", "/F", "/PID", strconv.Itoa(command.Process.Pid)).Run()
}

// defaultRuntimeBase is a per-user directory for the daemon socket. Windows has
// no numeric uid, and its temporary directory is already per user.
func defaultRuntimeBase() string {
	return filepath.Join(os.TempDir(), "taskspec")
}

// sandboxHostSupported is false: the container runs as the host uid:gid, which
// Windows does not have, and isolation that cannot be proven is not attempted.
func sandboxHostSupported() bool { return false }

// RestrictSocket is a no-op on Windows: permission bits do not apply to an
// AF_UNIX socket there, and the socket lives in the user's own temporary directory.
func RestrictSocket(path string) error {
	return nil
}
