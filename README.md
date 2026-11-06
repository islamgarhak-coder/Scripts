# Windows Scripts

This repository contains Windows administration scripts. The GitHub repository is the source of truth for published scripts and their documentation. Changes to scripts should be accompanied by updated usage documentation and an entry in [CHANGELOG.md](./CHANGELOG.md).

## Unquoted service executable paths

`Fix-UnquotedServicePaths.ps1` checks local Windows services for unquoted executable paths containing spaces. It does not change anything by default. It records identified paths and paths that need manual review in a timestamped CSV report, and writes compact JSON results to standard output.

Run in an elevated PowerShell session to inspect a computer:

```powershell
.\Fix-UnquotedServicePaths.ps1 -Mode Audit
```

Review the CSV, then explicitly request remediation:

```powershell
.\Fix-UnquotedServicePaths.ps1 -Mode Remediate
```

The script quotes only the executable portion, preserves any command-line arguments, and updates service configuration through `Win32_Service.Change`. It will not change a path if it cannot verify the executable file. Use `-WhatIf` with `-Mode Remediate` to preview changes:

```powershell
.\Fix-UnquotedServicePaths.ps1 -Mode Remediate -WhatIf
```

### Configuration Manager (SCCM)

This script is designed to run on a device through **Software Library > Scripts** (Configuration Manager Run Scripts). Add the `Mode` string parameter when creating the script, with `Audit` as its default and `Remediate` as the explicit remediation value. After running it on a pilot collection, view per-device results under **Monitoring > Script Status**; each JSON result includes the computer name, service name, original path, proposed path, and status. The script also writes a per-device CSV report at the reported `ReportPath`.

Configuration Manager's Run Scripts output is size-limited. The script caps detailed output at 3,000 UTF-8 bytes and reports the number of omitted service records in its final summary; use the per-device CSV or a separate centralized reporting method if a device has enough findings to exceed that cap. SCCM's script execution status indicates whether the script ran, while each JSON record's `Status` indicates whether a service was audited, remediated, or needs review.

Run and review the report on a pilot computer before targeting a production collection. The script operates on the computer where it runs and does not restart services. Schedule a maintenance window if a service needs restarting to use its updated command line.

## Libcurl inventory

`LibcurlInventory\Get-LibcurlInventory.ps1` is a separate, read-only inventory script. It searches common application, shared-data, user-profile, and Windows system directories, plus install locations registered for installed applications, for `libcurl*.dll` files. It reports file/product versions and flags versions below `8.22.0`. It also checks accessible running processes for loaded modules matching `libcurl*.dll` and correlates them with DLL paths.

The script does not change files, applications, or services and does not query other computers over the network. Deploy it through Configuration Manager **Software Library > Scripts** to inventory endpoints locally. Per-device output is available in **Monitoring > Script Status**; detailed CSV results are saved on each endpoint under `%ProgramData%\LibcurlInventory`. The script limits its JSON output to fit within the Configuration Manager Run Scripts output budget and reports omitted records in the summary.

The `8.22.0` comparison is the requested minimum version, not a claim that it is the latest upstream release. Update the `$minimumVersion` value in the script if your organization adopts a different baseline. Process-module inspection and filesystem enumeration can be restricted by process or directory permissions; the summary reports access and scan errors. A scan only identifies files named `libcurl*.dll`; renamed libraries and files outside the scanned roots may not be found. Application attribution uses registered install locations and DLL metadata, while “LoadedByProcesses” indicates observed runtime use at scan time.

## Change history

See [CHANGELOG.md](./CHANGELOG.md) for a record of notable script and documentation changes.
