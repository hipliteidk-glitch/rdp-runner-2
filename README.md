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

| Image | OS | SKU | GPU | Gate result |
| --- | --- | --- | --- | --- |
| `windows-2022` | Server 2022 Datacenter 21H2, build 20348.5622 | server | none (`Microsoft Hyper-V Video`, 0 MB) | killed, `0xC0000409` |
| `windows-latest` | Server 2025 Datacenter 24H2, build 26100.33438 | server | none | killed, `0xC0000409` |
| `windows-11-arm` | Windows 11 Enterprise 25H2, build 26200.9457, arm64 | **client** | none | killed, `0xC0000409` |

The last row looked decisive, but the real cause is simpler - and Roblox documents it. Roblox's
anti-cheat support article lists the crash type **"Virtual machine detected"**, with the user
message *"Roblox cannot run inside of a virtual machine."*, and states: **"Roblox requires GPU
passthrough to function properly within a VM."** A Roblox staff reply on the DevForum puts it in
one line: *"We prevent playing in a VM without a dedicated GPU."*

- <https://en.help.roblox.com/hc/en-us/articles/24275616578708-Anti-cheat-Messages>
- <https://devforum.roblox.com/t/hyperion-crash/2838411?page=2>

Every free GitHub-hosted Windows image is a VM with **no GPU at all** - the only display adapter
is `Microsoft Hyper-V Video`, 0 MB - so every one of them is rejected out of hand. That is why
the SKU question was a red herring: the Server/Client difference decides nothing here, the
missing GPU does. The arm64 row fails for the documented emulated-x64 reason *in addition* to
this one (`InstallerFailedToLaunchClient` / `wait result: 258`, install itself fine), and that
single run cannot separate the two.

Two measurements back the GPU explanation (both 2026-10-17):

- **A display is not what it wants.** Run 39055360837 installs a signed virtual display adapter
  *before* the Player runs, so a second adapter really does appear (`Virtual Display Driver`,
  `ROOT\DISPLAY\0000`) - and the verdict does not move: still `0xC0000409`. Detail below.
- **The death leaves no trace.** In that same run no `Application Error` / Windows Error
  Reporting event naming Roblox appears within 30 s, i.e. the Player ends itself instead of
  crashing. Reproduced live on the `windows-2022` runner inside the RDP session: exit
  `0xC0000409` after **0.28 s**, no WER report, no client log, no Application-log entry.

So **no free GitHub-hosted Windows image can run the Roblox Player**, and the honest reason is a
Roblox policy rather than a missing workaround: a VM needs a dedicated GPU. A machine that has
one is the only environment still untested, and there are exactly two ways to get one - see
*Two ways to get a green gate* below. Note the workflow is arch-aware: on arm64 it installs Tailscale's
**x86** package (Tailscale's documented choice for ARM64; the `-arm64.msi` installs and
starts its service but the node never leaves `NoState`), and it searches
`C:\Program Files (ARM)` as well as the x64 roots, because Program Files is redirected for
a native arm64 process.

### The display-adapter hypothesis - tested, and eliminated

Every environment that has killed the Player so far had **no display adapter at all** - just
`Microsoft Hyper-V Video`. That was the most obvious remaining confound, so the workflow can
install the [Virtual Display Driver](https://github.com/VirtualDrivers/Virtual-Display-Driver)
(VDD) *before* the Player runs (`virtual_display: true`).

It installs, and it settles the question. Measured on `windows-latest` in run 39055360837:

| | |
|---|---|
| adapter after install | `Microsoft Hyper-V Video, Virtual Display Driver` (`ROOT\DISPLAY\0000`, `OK`) |
| nefcon | `Device and driver installed successfully` |
| Player | still `FAIL - Player exited early with 0xC0000409` |

So **having a real monitor is not what Hyperion objects to.** The step stays in the workflow
because it takes that variable out of every future probe:

- VDD is a signed IddCx indirect display driver, installed via `nefcon` with its SignPath
  certificate trusted in `LocalMachine\TrustedPublisher` - so no test-signing and **no
  reboot**, which matters because a hosted job cannot survive a reboot.
- The step is best-effort (`continue-on-error`) and records the adapter list in the run summary
  *and* in `roblox-diag.txt`, so a FAIL can never be misread as "Hyperion rejects a machine
  that has a monitor".
- It is skipped on ARM64, where this driver needs test-signing plus a reboot.

That leaves exactly two untested variables, and both change at once when the larger runner is
used: an x64 **client** SKU (every passing-SKU probe so far was emulated on ARM64) and a real
**GPU**. One larger-runner probe therefore answers it - see the next section.

### Two ways to get a green gate

Every *free* hosted image is now measured and dead, so `expect: fail` is the honest
default. A green gate needs a machine with a **dedicated GPU** - the one property every
environment measured above lacks, and the one Roblox names in its own documentation. That
leaves exactly two options, neither of which is a standard hosted runner:

**1. A larger runner with a GPU** (paid, but cheap per probe). GitHub's larger runners are
not limited to Server SKUs: they can be created with the partner image **Base Windows 11
desktop**, i.e. a real x64 Windows 11 **client** SKU cloud machine - and the GPU flavour
adds a **Tesla T4**. That is the only GitHub configuration with a dedicated GPU, so it is
the only one that matches Roblox's requirement. Costs, from GitHub's published rates:

| Configuration | Rate | 1 hour of RDP | 6-minute probe |
| --- | --- | --- | --- |
| Windows 4-core larger runner (no GPU) | $0.022/min | $1.32 | ~$0.13 |
| Windows 4-core + 1x Tesla T4 (GPU) | $0.102/min | $6.12 | ~$0.61 |

Do **not** spend the probe on the CPU-only larger runner: it has no GPU, so by the
documented rule it fails exactly like the free images do.

Requirements and setup:

1. Larger runners are only available to **organizations** on **GitHub Team**
   ($4/user/month) or Enterprise Cloud - not to personal accounts - and they are **not
   free for public repositories**. A card on file and an Actions spending limit above zero
   are both required.
2. Org settings -> Actions -> Larger runners -> **New larger runner**: Windows, 4-core, add
   the **Tesla T4** GPU, image **Base Windows 11 desktop**; allow this repository to use it
   and note the runner's name.
3. Dispatch this workflow with `runner_label: <the runner's name>` and `expect: any` for a
   first probe (unknown environment: the run records the result and stays green either way).
4. If the Player survives, you have a real cloud Roblox RDP box - switch to `expect: run`,
   give it a long `keep_alive_minutes` and keep it. This is the outcome the GPU is being
   paid for.
5. If it still dies with a dedicated GPU, then no GitHub-hosted machine of any kind can run
   it and option 2 is the answer.

**2. A self-hosted runner on hardware you own** (free). Register a runner on a Windows 10/11
x64 PC **with a GPU** (repo or org Settings -> Actions -> Runners) and dispatch with
`runner: self-hosted`, `expect: run`. This is the free way to test the machine class Roblox
actually supports. Be aware the workflow then runs *on that PC*: it enables RDP, installs
Tailscale and installs the Roblox Player there.

One field note worth knowing before you judge a GPU probe: on a GPU-passthrough VM, users
report the Player tripping when a **monitor is attached to the virtual graphics adapter** -
only the real GPU should be presenting a display. On a larger runner you do not control
that, which is exactly what the probe is measuring.

### Using it

`workflow_dispatch` takes:

| Input | Meaning |
| --- | --- |
| `runner` | `windows-2022`, `windows-latest`, `windows-11-arm` (arm64), `self-hosted`, or any larger runner |
| `runner_label` | Free text; overrides `runner` when set, so a larger runner can be targeted by name |
| `expect` | `fail` (default - correct for every free hosted image), `run` (correct for a machine with a dedicated GPU), or `any` (unknown environment: record the result, stay green) |
| `keep_alive_minutes` | How long to leave the machine (and its RDP door) up |
| `virtual_display` | `true` installs the Virtual Display Driver before the Player test (measured: it adds a second adapter and does **not** change the verdict) |
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
