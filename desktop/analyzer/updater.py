"""Update check against desktop/latest.json in the repo, and in-place replacement of the running .exe."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import urllib.request
from dataclasses import dataclass

from . import __version__
from ._build import BUILD

MANIFEST_URL = "https://raw.githubusercontent.com/NB6RULES/OBRA-Essentials/main/desktop/latest.json"
DOWNLOAD_PAGE = "https://github.com/NB6RULES/OBRA-Essentials/releases/tag/analyzer-latest"
USER_AGENT = f"OBRA-Run-Analyzer/{__version__}"


@dataclass
class Release:
    version: str
    build: int
    url: str
    notes: str = ""
    date: str = ""
    size: int = 0

    @property
    def label(self) -> str:
        return f"{self.version} (build {self.build})"


def current_label() -> str:
    return f"{__version__} (build {BUILD})" if BUILD else f"{__version__} (from source)"


def parse_manifest(text: str) -> Release:
    d = json.loads(text)
    return Release(version=str(d["version"]), build=int(d["build"]), url=str(d["url"]),
                   notes=str(d.get("notes", "")), date=str(d.get("date", "")), size=int(d.get("size", 0) or 0))


def is_newer(rel: Release, build: int = BUILD) -> bool:
    return build > 0 and rel.build > build


def fetch_latest(timeout: float = 8.0, url: str = MANIFEST_URL) -> Release:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT, "Cache-Control": "no-cache"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return parse_manifest(r.read().decode("utf-8"))


def can_self_update() -> bool:
    """True for the packaged Windows .exe sitting in a folder we can write to."""
    if not getattr(sys, "frozen", False) or os.name != "nt":
        return False
    folder = os.path.dirname(sys.executable)
    try:
        fd, probe = tempfile.mkstemp(dir=folder, prefix=".obra-write-test-")
        os.close(fd)
        os.remove(probe)
        return True
    except OSError:
        return False


def staging_path() -> str:
    return sys.executable + ".new"


def download(rel: Release, dest: str, progress=None, cancelled=None, timeout: float = 30.0) -> None:
    """Downloads the new .exe to dest. progress(done, total) is called as it goes."""
    req = urllib.request.Request(rel.url, headers={"User-Agent": USER_AGENT})
    tmp = dest + ".part"
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r, open(tmp, "wb") as f:
            total = int(r.headers.get("Content-Length") or rel.size or 0)
            done = 0
            while True:
                if cancelled and cancelled():
                    raise InterruptedError("cancelled")
                chunk = r.read(256 * 1024)
                if not chunk:
                    break
                f.write(chunk)
                done += len(chunk)
                if progress:
                    progress(done, total)
        if total and done != total:
            raise OSError(f"download incomplete ({done} of {total} bytes)")
        with open(tmp, "rb") as f:
            if f.read(2) != b"MZ":
                raise OSError("the downloaded file isn't a Windows program")
        os.replace(tmp, dest)
    finally:
        if os.path.exists(tmp):
            try:
                os.remove(tmp)
            except OSError:
                pass


SWAP_SCRIPT = r"""@echo off
setlocal
set "NEW=%~1"
set "OLD=%~2"
set /a N=0
:retry
move /Y "%NEW%" "%OLD%" >nul 2>&1
if not errorlevel 1 goto swapped
set /a N+=1
if %N% GEQ 90 exit /b 1
ping -n 2 127.0.0.1 >nul
goto retry
:swapped
start "" "%OLD%" %3 %4 %5 %6 %7
(goto) 2>nul & del "%~f0"
"""


def swap_and_restart(new_exe: str, target_exe: str | None = None, args: list[str] | None = None) -> None:
    """Starts a helper that waits for this program to exit, replaces target_exe with new_exe and starts it again.
    The caller must quit straight after."""
    target_exe = target_exe or sys.executable
    fd, script = tempfile.mkstemp(suffix=".cmd", prefix="obra-update-")
    with os.fdopen(fd, "w", encoding="ascii", newline="\r\n") as f:
        f.write(SWAP_SCRIPT)
    # The one-file program passes private variables to child processes; the new copy must not inherit them.
    env = {k: v for k, v in os.environ.items() if not (k.startswith("_PYI_") or k.startswith("_MEI"))}
    env["PYINSTALLER_RESET_ENVIRONMENT"] = "1"
    flags = getattr(subprocess, "CREATE_NO_WINDOW", 0) | getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
    subprocess.Popen(["cmd.exe", "/c", script, new_exe, target_exe, *(args or [])], env=env, close_fds=True,
                     creationflags=flags, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL, cwd=os.path.dirname(target_exe) or None)
