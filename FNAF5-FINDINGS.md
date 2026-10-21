# FNaF 5 (Sister Location) — port status on `darkosre-r36`

Status check of the **Five Nights at Freddy's 5** port on the handheld
`darkosre-r36` (Anbernic RG351MP, RK3326 / Mali-G31, dArkOS RE, aarch64).

**Short version: FNaF 5 was already ported and it works.** It boots, holds
~60 FPS and renders its opening screen correctly. The only thing that looked
like a black-screen bug was the test harness holding the DRM master, not the
port.

## What "FNaF 5" means

*Five Nights at Freddy's: Sister Location* is the fifth entry in the series and
is routinely called **FNaF 5** (the Fandom wiki: "often referred to as Five
Nights at Freddy's 5 or FNaF 5"). So there was nothing to port — SL is FNaF 5,
and `/roms/ports/sl` already existed.

## What is on the device

| Path | Size | Notes |
| --- | --- | --- |
| `/roms/ports/Sister Location.sh` | 4.7 KB | launcher, PortMaster conventions |
| `/roms/ports/sl/Chowdren` | 8.4 MB | ELF 64-bit aarch64 PIE, not stripped, interp `/lib/ld-linux-aarch64.so.1` |
| `/roms/ports/sl/Assets.dat` | 387.9 MB | game data |
| `/roms/ports/sl/gl4es.aarch64/` | | `libGL.so.1`, `libEGL.so.1` (gl4es v1.1.7) |
| `/roms/ports/sl/libs.aarch64/` | | libbsd, libmd, X11/Xau/xcb/Xdmcp |
| `/roms/ports/sl/mousefix.so` + `.c` | 73 KB | source ships alongside the .so |
| `/roms/ports/sl/screenfix.so` + `.c` | 71 KB | source ships alongside the .so |
| `/roms/ports/sl/capshim.so` | 70 KB | capture shim |
| `/roms/ports/sl/slclassic` | 28 B | ini, `[sl] current=1`, `[] intro=1` |

Launcher environment that matters:

```
ALSOFT_DRIVERS=alsa  ALSOFT_NO_CONFIG=1
LIBGL_ES=1        # GLES 1.1 backend - GLES 2 drops textured geometry on Mali-G31
LIBGL_FB=4
LIBGL_BATCH=100   # the main-menu feedback effect is ~940 quads/frame
LD_PRELOAD="$GAMEDIR/mousefix.so:$GAMEDIR/screenfix.so:$GAMEDIR/gl4es.aarch64/libGL.so.1"
```

`screenfix.so` exists because Chowdren renders 1280x720 into an offscreen FBO
and composites it; on this GLES1/gl4es stack that FBO is never complete
(`0x8CD7 MISSING_ATTACHMENT`), so the shim keeps draws on the window and writes
into the 640x360 letterbox. `mousefix.so` restores mouse input, because this
Chowdren build's platform layer is gamepad-only and `platform_get_mouse_pos()`
is a stub returning 640/360.

## Test method

Over SSH (Tailscale), with EmulationStation controlling the framebuffer:

```bash
sudo -n fbgrab /tmp/sl_fb.png     # capture
# analyse: a 133-byte PNG == uniform frame == black screen
```

## Result A — EmulationStation still running

| Metric | Value |
| --- | --- |
| Framerate (game's own log) | 61.13 |
| `fbgrab` PNG size | **133 bytes** |
| Frame content | uniform (black) |

A 133-byte 640x480 PNG cannot encode anything but one flat colour. That is the
same tell `FNAF4-FINDINGS.md` records for the fnaf4 black screen.

## Result B — EmulationStation stopped, DRM master free

Same binary, same launcher, only difference is that `emulationstation.service`
was stopped first.

| Metric | Value |
| --- | --- |
| Framerate (game's own log) | 59.45 |
| `fbgrab` PNG size | **30083 bytes** |
| Frame size / format | 640x480, RGB8 |
| Distinct colours | 1717 |
| Average colour | (0, 1, 2) — a dark screen, as expected |
| Centre pixel | (255, 255, 255) |

The frame is ~96% black with a small bright UI block in the middle, and the
glyphs are clean and correctly formed (no smearing, no white-out).

Decoding the heading pixel-by-pixel segments it as `W A R N I N G :` —
this is Sister Location's **flashing-lights / jumpscare warning screen**, i.e.
the very first screen the game shows. Text renderer, font, scaling and
letterboxing all work.

## Root cause of the "black screen"

Not the port. gl4es is running on GBM against `/dev/dri/card0`:

```
LIBGL: using GBM
LIBGL: Using GLES 1.1 backend
LIBGL: GBM on card /dev/dri/card0 is Available
```

KMS needs to be the DRM master to do a modeset. EmulationStation owns the
master (`fuser -v /dev/dri/card0` → `emulationstatio`), so the game can create
surfaces and draw at 60 FPS, but nothing reaches the scanout — `fbgrab` then
shows one flat colour. Stop ES and the identical launch renders normally.

This is a test-harness artefact, not a shipping bug: PortMaster launches the
port *after* ES has given up the display.

## Log lines worth knowing

| Line | Verdict |
| --- | --- |
| `Linker failure: <4 raw bytes>` | Printed once at startup. Also present in the 2026-10-20 log. The game carries on at 59-61 FPS, so a stripped/unresolved symbol is non-fatal. |
| `LIBGL: Error while gathering supported extension (eglInitialize: EGL_BAD_DISPLAY)` | gl4es probes an EGL display that does not exist under GBM/KMSDRM. Cosmetic. |
| `[ALSOFT] (EE) Could not query RTKit` | No PipeWire/RTKit session on dArkOS; OpenAL falls back to ALSA. `ALSOFT_DRIVERS=alsa` is exactly the right mitigation. |
| `screenfix: remapped_vp=228 suppressed_present=228 canvas_tex=0` | The shim is doing its job. |
| `mousefix: TOTAL patched=3 rel=0 abs=0 moves=0 clicks=0` | 3 symbols patched (`platform_get_mouse_pos`, `FrameObject::get_x`, `FrameObject::get_y`); zero movement because the headless test pressed nothing. |

Audio stack initialises: `ALSOFT 1.24.2`, ALSA card `rockchiprk817co`, `rk817-hifi`.

## Traps for the next session

1. **`pgrep -x emulationstation` and `pkill -x emulationstation` silently do
   nothing.** `emulationstation` is 16 characters and the kernel `comm` field is
   15, so a `-x`/name match never hits; `pgrep -c` then reports 0 and the
   restore step thinks ES is dead when it is fine. Use `pgrep -f` /
   `pkill -f`.
2. **ES is a systemd unit, not a bare process.**
   `sudo systemctl stop|start emulationstation.service`. `nohup ... &` will not
   bring it back.
3. **`scp`/`ssh` from the Windows side need the `SSH_ASKPASS` env** or they sit
   on an interactive prompt and time out.
4. **Free space is tight** — 1.2 GB free of 11 GB (89% used), with a 388 MB
   `Assets.dat` in the port.
5. Backlight can come up at 8/160 after a cold boot; the launcher raises it to
   120, which is why a "dead" port can just be a dim panel.

## Changes made

* No permanent change to the port.
* `emulationstation.service` was stopped for the test and **restarted**;
  it is `active` and holds `/dev/dri/card0` again.
* The previous `log.txt` was preserved to `/tmp/sl_log_backup.txt` before the
  launcher truncated it.
* Captures on the device: `/tmp/sl_fb.png` (ES running, black) and
  `/tmp/sl_fb3.png` (DRM free, real frame).

## Still to verify

* **Interactive input.** The headless run pressed nothing, so `mousefix`
  reported `moves=0 clicks=0`. Needs a human with the pad: does the warning
  screen accept a click and does the main menu navigate?
* **Audio in practice.** OpenAL and the ALSA device come up; whether anything is
  actually audible has not been confirmed.
* **Progression past the warning screen** into the menu and first night.
