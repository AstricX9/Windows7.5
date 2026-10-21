# Windows 7 Continued

This repository prepares a safe, organised workspace for future Windows 7 Continued development. Current scope is environment setup only.

## Environment

- Windows 11 host; Windows PowerShell 5.1 is the initial scripting environment.
- IntelliJ IDEA 2026.2.1; Git repository is `repo/` only.
- `tools/`, `docs/`, `tests/`, and `reports/` are within `repo/`. `media/` and `vms/` are sibling folders and are not part of Git.

## Working rules

- Use clear, descriptive PowerShell names, approved verbs, and 4-space indentation. Save text as UTF-8; use CRLF for PowerShell files.
- Keep work scoped to the requested task. Prefer small, reviewable changes and avoid unnecessary tools, dependencies, or generated files.
- Treat installation media, system files, and VM contents as read-only. Never modify Windows installation media or VM files without explicit authorization.
- Do not recursively scan ISO/media or VM directories. Do not open or hash large ISO files as part of routine discovery.
- Test scripts with safe inputs and report exactly what was verified. Do not claim a check passed unless it was run.
