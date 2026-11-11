//go:build !windows

package mesh

import (
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"syscall"
)

// SetProcessGroup starts the command as the leader of its own process group, so
// TerminateProcessGroup can stop it together with every child it spawned.
func SetProcessGroup(command *exec.Cmd) {
	command.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
}

// TerminateProcessGroup asks the whole process group to stop.
func TerminateProcessGroup(command *exec.Cmd) error {
	return syscall.Kill(-command.Process.Pid, syscall.SIGTERM)
}

// defaultRuntimeBase is a per-user directory for the daemon socket.
func defaultRuntimeBase() string {
	return filepath.Join(os.TempDir(), "taskspec-"+strconv.Itoa(os.Getuid()))
}

// sandboxHostSupported reports whether the autonomous container can run as the host user.
func sandboxHostSupported() bool { return true }

// RestrictSocket limits the daemon socket to its owner.
func RestrictSocket(path string) error {
	return os.Chmod(path, 0o600)
}
