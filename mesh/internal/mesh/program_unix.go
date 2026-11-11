//go:build !windows

package mesh

import "os/exec"

// gitPlatformArguments precede every TaskMesh git command; POSIX needs none.
var gitPlatformArguments []string

// ResolveProgram finds an adapter program. It returns the executable to start
// and any arguments that must precede the adapter's own; POSIX needs none.
func ResolveProgram(name string) (string, []string, error) {
	executable, err := exec.LookPath(name)
	return executable, nil, err
}
