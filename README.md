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

## Roblox Player test (`roblox-test.yml`)

Probes whether a runner image can actually run the Roblox Player. The Player ships
with Byfron/Hyperion anti-cheat, which on a rejected environment terminates the
client about 400 ms after launch with `0xC0000409`
(`STATUS_STACK_BUFFER_OVERRUN`) - no client log, no crash dump, no message.

### Measured baseline

Client `0.743.0.7431134` (`version-11f155f3450f4c8e`). Every hosted image is rejected,
and all three fail with the same signature:

| Image | OS | SKU | Gate result |
| --- | --- | --- | --- |
| `windows-2022` | Server 2022 Datacenter 21H2, build 20348.5622 | server | killed, `0xC0000409` |
| `windows-latest` | Server 2025 Datacenter 24H2, build 26100.33438 | server | killed, `0xC0000409` |
| `windows-11-arm` | Windows 11 Enterprise 25H2, build 26200.9457, arm64 | **client** | killed, `0xC0000409` |

The last row is the one that mattered. `windows-11-arm` is the only hosted image that
is *not* a Server SKU, so it was the last live hypothesis: if Hyperion's objection were
the SKU alone, the x64 Player should have survived there. It did not (run 39052640851).
The Player installed correctly - elevated, into `C:\Program Files\Roblox\Versions\<GUID>`
- started, and died with the same `0xC0000409` and no client log; the installer logged
`InstallerFailedToLaunchClient` / `wait result: 258`.

That run cannot separate the two remaining explanations - Hyperion rejecting x64 code
under emulation, or rejecting the VM underneath - but it does not have to: **no
GitHub-hosted Windows image can run the Roblox Player.** x64 hosted images are Server
SKUs and are rejected on SKU; the only client-SKU image is arm64 and is rejected under
emulation.

A green gate therefore needs a real x64 **Client-SKU** machine (Windows 10/11) - i.e. a
self-hosted runner, which is what `runner: self-hosted` and `expect: run` are for. Note
the workflow is arch-aware: on arm64 it installs Tailscale's **x86** package (Tailscale's
documented choice for ARM64; the `-arm64.msi` installs and starts its service but the
node never leaves `NoState`), and it searches `C:\Program Files (ARM)` as well as the
x64 roots, because Program Files is redirected for a native arm64 process.

### Using it

`workflow_dispatch` takes:

| Input | Meaning |
| --- | --- |
| `runner` | `windows-2022`, `windows-latest`, `windows-11-arm` (the client-SKU image), or `self-hosted` |
| `expect` | `fail` (default - correct for every hosted image) or `run` (a real x64 Client-SKU machine) |
| `keep_alive_minutes` | How long to leave the machine (and its RDP door) up |
| `hostname` | Tailscale node name (default `gh-roblox-test`); set a unique one for test runs so they cannot steal the address from a machine you are already using |

The run is **green while the image matches `expect`** and red when it does not, so
it works as a regression probe: it turns red if a future client starts surviving on
any hosted image (then set `expect: run`), or if a known-good image regresses. In
every case it uploads `roblox-diag-windows-*` containing the verdict, the Roblox
installer log and any client log, and leaves the machine reachable over Tailscale/RDP.

### Implementation notes

Two bugs used to make this workflow report a false failure before it ever reached
the gate:

- The install step only looked for `RobloxPlayerBeta.exe` under
  `%LOCALAPPDATA%\Roblox\Versions`, but the runner executes steps as an
  administrator, and an elevated install lands in
  `C:\Program Files\Roblox\Versions\<version GUID>`. A perfectly good install was
  reported as "not found". All three roots are searched now.
- The bootstrapper's stub exits within seconds (exit code 7) while the real install
  runs on in a child process, so a fixed 60 s probe was far too short. The step now
  watches the actual progress, caps at 600 s, and bails out after 90 s of no
  installer process and no growth.

The gate itself is measured by PID rather than process count, because the installer
launches the client once on its own at the end of the install; a leftover process
would otherwise make a dead Player look alive.
