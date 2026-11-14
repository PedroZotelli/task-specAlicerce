//go:build windows

package mesh

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// fakeHost lays out a Windows machine where PATH reaches the WSL launcher
// (System32\bash.exe) before anything from Git, as a native shell does, and
// returns the Git Bash that must be chosen instead.
func fakeHost(t *testing.T, launcherDirectory string) (pathValue, gitBash string) {
	t.Helper()
	root := t.TempDir()
	launcher := filepath.Join(root, launcherDirectory)
	gitCommand := filepath.Join(root, "Git", "cmd")
	gitBash = filepath.Join(root, "Git", "bin", "bash.exe")
	for _, file := range []string{
		filepath.Join(launcher, "bash.exe"),
		filepath.Join(gitCommand, "git.exe"),
		gitBash,
	} {
		if err := os.MkdirAll(filepath.Dir(file), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(file, nil, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	return launcher + string(os.PathListSeparator) + gitCommand, gitBash
}

func bashScript(t *testing.T) string {
	t.Helper()
	script := filepath.Join(t.TempDir(), "adapter.sh")
	if err := os.WriteFile(script, []byte("#!/usr/bin/env bash\nexit 0\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	return script
}

func sameFile(t *testing.T, got, want string) bool {
	t.Helper()
	left, errLeft := filepath.EvalSymlinks(got)
	right, errRight := filepath.EvalSymlinks(want)
	return errLeft == nil && errRight == nil && strings.EqualFold(left, right)
}

func TestResolveProgramNeverHandsAScriptToTheWSLLauncher(t *testing.T) {
	for _, launcherDirectory := range []string{
		filepath.Join("Windows", "System32"),
		filepath.Join("Windows", "SysWOW64"),
		filepath.Join("Users", "someone", "AppData", "Local", "Microsoft", "WindowsApps"),
	} {
		t.Run(launcherDirectory, func(t *testing.T) {
			pathValue, gitBash := fakeHost(t, launcherDirectory)
			t.Setenv("PATH", pathValue)
			script := bashScript(t)

			executable, leading, err := ResolveProgram(script)
			if err != nil {
				t.Fatalf("ResolveProgram: %v", err)
			}
			if isWSLLauncher(executable) {
				t.Fatalf("a bash script was handed to the WSL launcher: %s", executable)
			}
			if !sameFile(t, executable, gitBash) {
				t.Fatalf("interpreter = %s, want Git Bash %s", executable, gitBash)
			}
			if len(leading) != 1 || leading[0] != script {
				t.Fatalf("leading arguments = %v, want the script path", leading)
			}
		})
	}
}

func TestResolveProgramKeepsABashAlreadyOutsideTheLauncherDirectories(t *testing.T) {
	root := t.TempDir()
	msys := filepath.Join(root, "msys64", "usr", "bin", "bash.exe")
	if err := os.MkdirAll(filepath.Dir(msys), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(msys, nil, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", filepath.Dir(msys))

	executable, _, err := ResolveProgram(bashScript(t))
	if err != nil {
		t.Fatalf("ResolveProgram: %v", err)
	}
	if !sameFile(t, executable, msys) {
		t.Fatalf("interpreter = %s, want %s", executable, msys)
	}
}

func TestResolveProgramRefusesWhenOnlyTheWSLLauncherExists(t *testing.T) {
	launcher := filepath.Join(t.TempDir(), "Windows", "System32")
	if err := os.MkdirAll(launcher, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(launcher, "bash.exe"), nil, 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", launcher)

	executable, _, err := ResolveProgram(bashScript(t))
	if err == nil {
		t.Fatalf("expected a refusal, got %s", executable)
	}
	if !strings.Contains(err.Error(), "Git for Windows") {
		t.Fatalf("the refusal must name what to install, got: %v", err)
	}
}

func TestIsWSLLauncher(t *testing.T) {
	cases := map[string]bool{
		`C:\Windows\System32\bash.exe`:                            true,
		`C:\WINDOWS\system32\bash.EXE`:                            true,
		`C:/Windows/SysWOW64/bash.exe`:                            true,
		`C:\Users\x\AppData\Local\Microsoft\WindowsApps\bash.exe`: true,
		`C:\Program Files\Git\bin\bash.exe`:                       false,
		`C:\Program Files\Git\usr\bin\bash.exe`:                   false,
		`C:\msys64\usr\bin\bash.exe`:                              false,
	}
	for path, want := range cases {
		if got := isWSLLauncher(path); got != want {
			t.Errorf("isWSLLauncher(%q) = %v, want %v", path, got, want)
		}
	}
}
