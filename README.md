# RDP Runner

Windows GitHub Actions runner that configures Remote Desktop, joins Tailscale and
builds interactively. Workflow: `.github/workflows/rdp-build.yml`
(`workflow_dispatch` -> RDP up on Tailscale -> keep alive 6 h).

## Scripts

| Script | Purpose |
| --- | --- |
| `Enable-RDP.ps1` | Turns on Remote Desktop and prepares the RDP account (used by the workflow) |
| `Restore-PC.ps1` | Rebuilds a machine from a `Backup_<timestamp>` folder made by `Backup-PC.ps1` |

The workflow replaces the old inline "Configure RDP" and "Create RDP User" steps
with one call:

```powershell
./Enable-RDP.ps1 -User RDP -Password $pass -RecreateUser -Administrators `
  -Port 3389 -SecurityLayer 0 -FirewallRuleName "RDP-Tailscale" -RestartService -KeepTimeouts
```

That enables RDP, sets port 3389 and security layer 0 (legacy clients),
recreates the `RDP` user with `secrets.RDP_PASSWORD`, adds it to Administrators and
Remote Desktop Users, and opens the `RDP-Tailscale` firewall rule.

Run `./Enable-RDP.ps1 -WhatIf` to preview every change; add `-RequireNla` to
demand Network Level Authentication instead. The full script set (backup, restore,
RDP, README) lives in the private `pc-restore` repo.
