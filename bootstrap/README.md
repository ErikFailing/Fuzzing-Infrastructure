# Bootstrap

The scripts that build the fuzzing workstation from nothing, numbered in the order they run. Each one checks what's
already there before it changes anything: missing things are installed, Windows-side tools are updated when a newer
version is waiting, and nothing is reinstalled over a good install. Running one again is always safe.

The plan: WSL2 with an Ubuntu 24.04 distro as the Linux host, Docker Engine inside Ubuntu, and the fuzzing toolchain
(LLVM, AFL++, sanitizers, triage tools) in a pinned Docker image, so the exact toolchain that found a crash can be
rebuilt or kept, and run the same way in CI or on a rented Linux box.

| Script | What it does |
|---|---|
| `01-install-windows-tools.ps1` | Installs WSL2, Ubuntu 24.04, Windows Terminal, VS Code with its WSL and Dev Containers extensions, Git for Windows and PowerShell 7, and updates any of them that has a newer version waiting. |

Run the Windows scripts from a normal (not admin) PowerShell in the repo root, with a `-WhatIf` dry run first:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\bootstrap\01-install-windows-tools.ps1 -WhatIf
powershell -NoProfile -ExecutionPolicy Bypass -File .\bootstrap\01-install-windows-tools.ps1
```

Exit code 3010 means reboot Windows, then run the same script again. When it finishes, open Ubuntu once from Windows
Terminal and create your Linux user when it asks.
