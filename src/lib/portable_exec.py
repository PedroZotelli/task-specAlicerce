"""Start programs and scripts the same way on Linux, macOS, and Windows.

POSIX runs a shebang script by name. Windows starts only real executables: npm
installs `.cmd` shims that a bare name does not find, and an extensionless
script raises WinError 193. These helpers resolve the program and, for a script,
prepend the interpreter its shebang names. Off Windows they change nothing.
"""

from __future__ import annotations

import os
import pathlib
import shutil
import sys

_NATIVE_SUFFIXES = {".exe", ".com", ".cmd", ".bat"}


def _is_wsl_launcher(path: str) -> bool:
    lowered = path.replace("/", "\\").lower()
    return any(part in lowered for part in ("\\windows\\system32\\", "\\windows\\syswow64\\", "\\windowsapps\\"))


def bash_executable() -> str:
    """The bash that runs Task-Spec scripts: "bash" off Windows, Git Bash's full path on it.

    Windows looks for a bare program name in System32 before PATH, and
    System32\\bash.exe is the WSL launcher, so a bare "bash" can start WSL.
    """
    if sys.platform != "win32":
        return "bash"
    found = shutil.which("bash")
    if found and not _is_wsl_launcher(found):
        return found
    git = shutil.which("git")
    if git:
        for root in pathlib.Path(git).resolve().parents[:3]:
            for relative in ("bin/bash.exe", "usr/bin/bash.exe"):
                candidate = root / relative
                if candidate.is_file():
                    return str(candidate)
    raise FileNotFoundError("Git for Windows bash was not found; install Git for Windows")


def find_program(name: str) -> str | None:
    """shutil.which, plus extensionless shebang scripts, which Windows PATHEXT skips."""
    found = shutil.which(name)
    if found is not None or sys.platform != "win32" or os.path.dirname(name):
        return found
    for directory in os.environ.get("PATH", "").split(os.pathsep):
        candidate = os.path.join(directory, name)
        if directory and os.path.isfile(candidate):
            return candidate
    return None


def resolve_command(argv: list[str]) -> list[str]:
    """Return argv ready for subprocess on this platform."""
    if sys.platform != "win32" or not argv:
        return argv
    program = argv[0]
    if program in {"bash", "sh", "bash.exe", "sh.exe"}:
        # A bare bash may resolve to the WSL launcher; always use Git Bash.
        return [bash_executable(), *argv[1:]]
    found = program if os.path.isfile(program) else find_program(program)
    if found is None:
        return argv
    if pathlib.Path(found).suffix.lower() in _NATIVE_SUFFIXES:
        return [found, *argv[1:]]
    with open(found, "rb") as handle:
        first = handle.readline().decode("utf-8", "replace")
    if first.startswith("#!"):
        interpreter = first[2:].split()
        if interpreter:
            name = pathlib.Path(interpreter[-1] if interpreter[0].endswith("/env") else interpreter[0]).name
            if name.startswith("python"):
                return [sys.executable, found, *argv[1:]]
            if name in {"bash", "sh"}:
                return [bash_executable(), found, *argv[1:]]
    return [found, *argv[1:]]
