# Changelog

Notable changes to this repository are recorded here. Entries are in reverse chronological order.

## 2026-11-06

### Added

- Added `notepad.txt` as provided.

- Added `Fix-UnquotedServicePaths.ps1` to audit and optionally remediate unquoted Windows service executable paths.
- Added Configuration Manager (SCCM) Run Scripts output for per-device service findings, plus a local CSV report under `%ProgramData%\UnquotedServicePaths`.
- Documented audit, remediation, preview, SCCM deployment, and reporting guidance in the README.
