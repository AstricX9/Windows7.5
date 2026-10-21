

\# Windows 7 Continued — Agent Instructions



\## Environment

\- Host: Windows 11 Pro

\- Target: Windows 7 SP1 x64, when confirmed

\- Initial language: Windows PowerShell 5.1

\- IDE: IntelliJ IDEA

\- Test platform: VirtualBox



\## Project structure

\- tools/: development scripts

\- docs/: project documentation

\- reports/: generated test results

\- ../media/: source installation media

\- ../vms/: virtual machines



\## Rules

\- Never modify or overwrite source ISO files.

\- Prefer read-only inspection.

\- Never assume Windows 11 DISM supports Windows 7 servicing.

\- Do not change VM networking or host security settings.

\- Make one logical change at a time.

\- Avoid unnecessary dependencies.

\- Reuse existing scripts instead of rewriting them.

\- Run relevant tests after each change.

\- Report failures and unverified assumptions.

\- Never claim a test passed unless executed.



\## Workflow

1\. Inspect only the relevant files.

2\. Explain the smallest necessary change.

3\. Implement that change.

4\. Run targeted checks.

5\. Summarise changes, results and limitations.



