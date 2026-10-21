"""Generate launcher icons for the 'Run Left' countdown APK."""
import os
from PIL import Image, ImageDraw

ROOT = r"C:\Users\RDP\Documents\Default Project\countdown-apk\res"
BG = (11, 15, 20, 255)
GREEN = (91, 228, 155, 255)
MUTED = (138, 151, 166, 255)

DENSITIES = {
    "mipmap-mdpi": 48,
    "mipmap-hdpi": 72,
    "mipmap-xhdpi": 96,
    "mipmap-xxhdpi": 144,
    "mipmap-xxxhdpi": 192,
}


def draw_clock(size, round_icon):
    ss = 4  # supersample
    s = size * ss
    img = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    if round_icon:
        d.ellipse([0, 0, s - 1, s - 1], fill=BG)
    else:
        d.rounded_rectangle([0, 0, s - 1, s - 1], radius=int(s * 0.22), fill=BG)

    # clock face
    pad = s * 0.17
    d.ellipse([pad, pad, s - pad, s - pad], outline=MUTED, width=max(2, int(s * 0.035)))

    # hour hand (up), minute hand (right) -> a quarter past, i.e. time left
    cx = cy = s / 2
    r = (s - 2 * pad) / 2
    d.line([cx, cy, cx, cy - r * 0.60], fill=GREEN, width=max(2, int(s * 0.045)))
    d.line([cx, cy, cx + r * 0.45, cy + r * 0.28], fill=GREEN, width=max(2, int(s * 0.045)))
    d.ellipse([cx - s * 0.03, cy - s * 0.03, cx + s * 0.03, cy + s * 0.03], fill=GREEN)

    return img.resize((size, size), Image.LANCZOS)


for folder, size in DENSITIES.items():
    out_dir = os.path.join(ROOT, folder)
    os.makedirs(out_dir, exist_ok=True)
    draw_clock(size, False).save(os.path.join(out_dir, "ic_launcher.png"))
    draw_clock(size, True).save(os.path.join(out_dir, "ic_launcher_round.png"))
    print(f"{folder}: {size}x{size}")

print("icons done")
