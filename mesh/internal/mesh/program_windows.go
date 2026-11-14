//go:build windows

package mesh

import (
	"bufio"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// gitPlatformArguments precede every TaskMesh git command. Worktrees and
// acceptance records nest deeply, past the 260-character Windows path limit.
var gitPlatformArguments = []string{"-c", "core.longpaths=true"}

// ResolveProgram finds an adapter program. Windows starts only files with an
// executable suffix, so a shebang script is handed to the interpreter it names:
// the returned arguments (the script path) must precede the adapter's own.
func ResolveProgram(name string) (string, []string, error) {
	executable, err := exec.LookPath(name)
	// LookPath also accepts an existing file such as fake.sh, which Windows then refuses to start.
	if err == nil && nativeExecutable(executable) {
		return executable, nil, nil
	}
	script := executable
	if err != nil {
		script = scriptPath(name)
	}
	if script == "" {
		return "", nil, err
	}
	interpreter := shebangInterpreter(script)
	if interpreter == "" {
		if err == nil {
			return executable, nil, nil // not a script: let Windows report why it cannot start
		}
		return "", nil, err
	}
	var found string
	var lookErr error
	if interpreter == "bash" {
		found, lookErr = gitBash()
	} else {
		found, lookErr = exec.LookPath(interpreter)
		if lookErr != nil && interpreter == "python3" {
			found, lookErr = exec.LookPath("python")
		}
	}
	if lookErr != nil {
		return "", nil, lookErr
	}
	return found, []string{script}, nil
}

// isWSLLauncher reports whether a bash.exe is the WSL launcher rather than a
// shell. System32, SysWOW64, and WindowsApps hold the launcher: it starts a
// Linux distribution that does not see the adapter script or the repository.
func isWSLLauncher(path string) bool {
	lowered := strings.ToLower(strings.ReplaceAll(path, "/", `\`))
	for _, part := range []string{`\windows\system32\`, `\windows\syswow64\`, `\windowsapps\`} {
		if strings.Contains(lowered, part) {
			return true
		}
	}
	return false
}

// gitBash returns the bash that runs adapter scripts: a bash already on PATH
// outside the launcher directories, or the one shipped with Git for Windows,
// found from git itself. A native shell's PATH reaches System32 first, so a
// bare "bash" lookup would start WSL. The same rule as src/lib/portable_exec.py.
func gitBash() (string, error) {
	if found, err := exec.LookPath("bash"); err == nil && !isWSLLauncher(found) {
		return found, nil
	}
	if git, err := exec.LookPath("git"); err == nil {
		if resolved, resolveErr := filepath.EvalSymlinks(git); resolveErr == nil {
			git = resolved
		}
		directory := filepath.Dir(git)
		for level := 0; level < 3; level++ {
			for _, relative := range []string{filepath.Join("bin", "bash.exe"), filepath.Join("usr", "bin", "bash.exe")} {
				candidate := filepath.Join(directory, relative)
				if info, statErr := os.Stat(candidate); statErr == nil && !info.IsDir() {
					return candidate, nil
				}
			}
			directory = filepath.Dir(directory)
		}
	}
	return "", errors.New("Git for Windows bash was not found; install Git for Windows (the WSL bash launcher is never used)")
}

func nativeExecutable(path string) bool {
	switch strings.ToLower(filepath.Ext(path)) {
	case ".exe", ".com", ".bat", ".cmd":
		return true
	}
	return false
}

func scriptPath(name string) string {
	if strings.ContainsAny(name, `/\`) {
		if info, err := os.Stat(name); err == nil && !info.IsDir() {
			return name
		}
		return ""
	}
	for _, directory := range filepath.SplitList(os.Getenv("PATH")) {
		candidate := filepath.Join(directory, name)
		if info, err := os.Stat(candidate); err == nil && !info.IsDir() {
			return candidate
		}
	}
	return ""
}

func shebangInterpreter(script string) string {
	file, err := os.Open(script)
	if err != nil {
		return ""
	}
	defer file.Close()
	line, err := bufio.NewReader(file).ReadString('\n')
	if (err != nil && line == "") || !strings.HasPrefix(line, "#!") {
		return ""
	}
	fields := strings.Fields(strings.TrimPrefix(line, "#!"))
	if len(fields) == 0 {
		return ""
	}
	name := filepath.Base(fields[0])
	if name == "env" && len(fields) > 1 {
		name = fields[len(fields)-1]
	}
	switch {
	case name == "bash" || name == "sh":
		return "bash"
	case strings.HasPrefix(name, "python"):
		return "python3"
	}
	return ""
}
