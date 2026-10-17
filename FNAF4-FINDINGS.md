# FNAF4 (Chowdren port) black screen — findings

Investigation of the **Five Nights at Freddy's 4** port on the handheld
`darkosre-r36` (Anbernic RG351MP, RK3326 / Mali-G31, dArkOS RE, aarch64).
The port runs at ~60 FPS but the screen is black.

## Symptom

- Game launches, logs a normal startup, holds ~60 FPS.
- `/dev/fb0` is a uniform black frame (PNG size 133 bytes, average `0 0 0`).
- The engine's own `log.txt` shows **no errors** (0 ASTC errors), unlike the
  sibling fnaf2 port.

## Root cause

The black screen is caused by **gl4es' GLES 2.0 backend**, not by the port.

With the launcher's current `LIBGL_ES=2`, gl4es fails to draw **any textured /
vertex-array geometry** on this device — only `glClear` works. The game clears
to black and then draws textured sprites via vertex arrays, none of which land,
so the framebuffer stays black.

Selecting the **GLES 1.1 backend** (`LIBGL_ES=1`) makes textured drawing work and
the screen is no longer black.

## Evidence

Control programs using the identical stack (SDL2 → gl4es → Mali via KMSDRM):

| Config | Textured quad renders? | fnaf4 screen |
| --- | --- | --- |
| `LIBGL_ES=2` (current) | no | black (`0 0 0`) |
| `LIBGL_ES=1` | yes | white (`255 255 255`) |

Readback probe (`glReadPixels` at screen centre):

```
LIBGL_ES=2 :  default after blue clear  =   0   0 255 255
              default after yellow quad =   0   0 255 255   <- quad NOT drawn
LIBGL_ES=1 :  default after blue clear  =   0   0 255 255
              default after yellow quad = 255 255   0 255   <- quad drawn
```

A GL-call shim (`LD_PRELOAD`) confirmed the engine *is* submitting draws with
`LIBGL_ES=2`: ~4632 `glDrawArrays`, 51 `glTexImage2D`, viewport `640x480`,
clear colour `(0,0,0,1)` — it simply never reaches the screen.

The engine also renders into its own offscreen FBO (`screen_fbo`) and composites
it; under gl4es that FBO reports
`GL_FRAMEBUFFER_INCOMPLETE_MISSING_ATTACHMENT` (`0x8CD7`), a second, related
gl4es issue.

## Remaining issue

After switching to `LIBGL_ES=1` the game renders but shows a **uniform white**
screen (`255 255 255`), not the real image. The next suspect is the engine's
16-bit texture-upload path (`CHOWDREN_16BIT_TEXUPLOAD` /
`CHOWDREN_RGBA4444_TEXUPLOAD`), i.e. `GL_UNSIGNED_SHORT_4_4_4_4` uploads possibly
being mishandled by gl4es.

## Fix to try

Set `LIBGL_ES=1` (instead of `2`) in the port launchers:

- `/roms/ports/fnaf4/fnaf4.sh`
- `/roms/ports/Five Nights at Freddys 4.sh`

## Changes made

None permanent. The launchers still use `LIBGL_ES=2`; the EGL wrapper and audio
(`ALSOFT_*`) tweaks from an earlier session are proven harmless and are not the
cause.

## Notes

- `/dev/fb0` capture: `sudo -n fbgrab`; brightness via
  `ffmpeg -i x.png -vf scale=1:1 -f rawvideo -pix_fmt rgb24 - | od -An -tu1`.
- EmulationStation holds the DRM master, so GL tests must stop it first and
  restart it afterwards. Two GPU hangs (running fnaf2, and an FBO-composite test)
  rebooted the device during this investigation; fnaf4 itself is stable.
- Test artifacts left in `/tmp` on the device: `gllog.c/.so`, `sdlv2.c`,
  `sdlv3.c`, `sdlred.c`, `run_es1.sh`, `runv3.sh`, and various `*.png`/`*.log`.
