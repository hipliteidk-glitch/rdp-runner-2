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

Why the arm64 row fails is documented, and it is not the VM: Roblox **blocks emulated x64
on purpose**. It ships no native ARM64 Windows client (the Microsoft Store build is
x64-only), and people on real Windows-on-ARM laptops - client SKU, real GPU, real display
adapter - hit the same failure from both the website installer and the Store, with Roblox
declining to support ARM64. Sources: Roblox DevForum
[roblox-fails-to-initialise-on-windows-arm64-devices](https://devforum.roblox.com/t/roblox-fails-to-initialise-on-windows-arm64-devices/4768214)
and
[resolved-roblox-fails-to-launch-on-arm64-windows-11](https://devforum.roblox.com/t/resolved-roblox-fails-to-launch-on-arm64-windows-11/3410091)
("disallowing software emulated playing").

So the arm64 run answered "can emulated x64 run" (no, by design) - it did **not** answer
the SKU question. A genuine x64 Client-SKU machine remains untested, which is exactly what
the next section is about. The practical conclusion is unchanged, though: **no free
GitHub-hosted Windows image can run the Roblox Player.**

One caveat on what these results can be attributed to: every environment measured here
also has **no real display adapter** (a basic/virtual display only), so the failures
cannot distinguish "rejected because Server SKU / x64 emulation" from "rejected because
there is no GPU". A real PC with a GPU is therefore still an untested environment, and the
cheapest way to test it is a self-hosted runner on one. The workflow now records the
display adapter, Secure Boot and TPM state in the job log, so the next environment tested
is directly comparable to these three.

A green gate therefore needs a real x64 **Client-SKU** machine; the two ways to get one are
in the next section. Note the workflow is arch-aware: on arm64 it installs Tailscale's
**x86** package (Tailscale's documented choice for ARM64; the `-arm64.msi` installs and
starts its service but the node never leaves `NoState`), and it searches
`C:\Program Files (ARM)` as well as the x64 roots, because Program Files is redirected for
a native arm64 process.

### The virtual display hypothesis (`virtual_display: true`)

Every environment that has killed the Player so far had **no display adapter at all** - just
`Microsoft Hyper-V Video`. That is a confound, and it is testable: the workflow can install
the [Virtual Display Driver](https://github.com/VirtualDrivers/Virtual-Display-Driver) (VDD)
*before* the Player runs, giving the machine a real monitor.

- VDD is a signed IddCx indirect display driver, installed via `nefcon` with its SignPath
  certificate trusted in `LocalMachine\TrustedPublisher` - so no test-signing and **no
  reboot**, which matters because a hosted job cannot survive a reboot.
- The step is best-effort (`continue-on-error`) and records the resulting adapter list in the
  run summary *and* in `roblox-diag.txt`, so a FAIL can never be misread as "Hyperion rejects
  a machine that has a monitor".
- It is skipped on ARM64, where this driver needs test-signing plus a reboot.

```shell
gh workflow run roblox-test.yml -f runner=windows-latest -f virtual_display=true \
  -f expect=fail -f keep_alive_minutes=0 -f hostname=gh-roblox-vdd
```

Read the result like this:

- run stays **green** (`fail`, as expected) - having a display changed nothing; the missing
  monitor is not what Hyperion objects to;
- run goes **red with a MISMATCH** - the Player *survived* on a free hosted runner simply
  because the machine now has a display, which would be the headline result.

### Two ways to get a green gate

Every *free* hosted image is now measured and dead, so `expect: fail` is the honest
default. A green gate needs a real x64 Client-SKU machine, and that leaves exactly two
options - neither of which is a standard hosted runner:

**1. A self-hosted runner on hardware you own** (free). Register a runner on a Windows 10/11
x64 PC (repo or org Settings -> Actions -> Runners) and dispatch with
`runner: self-hosted`, `expect: run`. This is the only way to test a machine with a real
display adapter, which is the one property every environment measured above lacks. Be aware
the workflow then runs *on that PC*: it enables RDP, installs Tailscale and installs the
Roblox Player.

**2. A larger runner with the "Base Windows 11 desktop" image** (paid, but cheap per run).
GitHub's larger runners are not limited to Server SKUs: they can be created with the
partner image **Base Windows 11 desktop**, i.e. a real x64 Windows 11 **client** SKU cloud
machine hosted by GitHub. Its GPU counterpart is the only configuration that is client SKU
*and* x64 *and* has a real GPU. Costs, from GitHub's published rates:

| Configuration | Rate | 1 hour of RDP |
| --- | --- | --- |
| Windows 4-core larger runner | $0.022/min | $1.32 |
| Windows 4-core + 1x Tesla T4 (GPU) | $0.102/min | $6.12 |

Requirements and setup:

1. Larger runners are only available to **organizations** on **GitHub Team**
   ($4/user/month) or Enterprise Cloud - not to personal accounts - and they are **not
   free for public repositories**. A card on file and an Actions spending limit above zero
   are both required.
2. Org settings -> Actions -> Larger runners -> **New larger runner**: Windows, 4-core,
   image **Base Windows 11 desktop**; then allow this repository to use it.
3. Dispatch this workflow with `runner_label: <the runner's name>` and `expect: any` for a
   first probe (unknown environment: the run records the result and stays green either way).
4. If the Player survives, you have a real cloud Roblox RDP box at $0.022/min - switch to
   `expect: run` and keep it.
5. If it still dies, repeat with a **GPU larger runner** (4-core + Tesla T4, same Windows 11
   desktop image). If the Player dies there too, then no GitHub-hosted machine of any kind
   can run it and option 1 is the answer.

### Using it

`workflow_dispatch` takes:

| Input | Meaning |
| --- | --- |
| `runner` | `windows-2022`, `windows-latest`, `windows-11-arm` (the client-SKU image), `self-hosted`, or any larger runner |
| `runner_label` | Free text; overrides `runner` when set, so a larger runner can be targeted by name |
| `expect` | `fail` (default - correct for every free hosted image), `run` (a real x64 Client-SKU machine), or `any` (unknown environment: record the result, stay green) |
| `keep_alive_minutes` | How long to leave the machine (and its RDP door) up |
| `virtual_display` | `true` installs the Virtual Display Driver before the Player test - see "The virtual display hypothesis" |
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
