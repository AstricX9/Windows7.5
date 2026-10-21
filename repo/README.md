# Windows 7 Continued

A clean development workspace for future Windows 7 Continued work. This repository currently contains environment setup and project guidance only; no operating-system modifications or ISO tooling are included.

## Layout

- `tools/` — future development utilities
- `docs/` — project documentation
- `tests/` — future checks
- `reports/` — generated reports (ignored by Git)
- `../media/` — external media storage, outside the repository
- `../vms/` — external VM storage, outside the repository

Only this `repo/` directory is a Git repository. Keep installation media and VM files outside version control and read-only.

## Windows ISO Inspector v0.1

Run the read-only inspector from IntelliJ's PowerShell terminal, using a quoted ISO path:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tools\Inspect-WindowsISO.ps1 -IsoPath "G:\Dev\Windows7.5\media\Windows 7.iso"
```

The report is written to a timestamped folder under `reports/` by default. The inspector needs an existing 7-Zip installation available as `7z.exe`, `7za.exe`, or `7zz.exe`; provide a specific executable with `-SevenZipPath` when needed. Use `-ReportRoot` to choose another output directory.

Run the temporary-fixture smoke tests with:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-Inspect-WindowsISO.ps1
```
