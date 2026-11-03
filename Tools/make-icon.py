#!/usr/bin/env python3
"""Draws the DeskDash app icon (needs Pillow: pip3 install pillow).

Writes Resources/Icon/AppIcon-1024.png and Resources/AppIcon.icns.
The picture: a ring split into colored parts (disk space by category) around three rising bars (AI tokens),
on a dark rounded square in the usual macOS icon size and shape.
"""
import math
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
S = 4  # draw 4x larger, then shrink, for smooth edges
N = 1024 * S


def sc(v):
    return int(v * S)


def gradient(size, top, bottom):
    img = Image.new("RGBA", (size, size))
    d = ImageDraw.Draw(img)
    for y in range(size):
        t = y / (size - 1)
        d.line([(0, y), (size, y)], fill=tuple(int(a + (b - a) * t) for a, b in zip(top, bottom)) + (255,))
    return img


def draw():
    canvas = Image.new("RGBA", (N, N), (0, 0, 0, 0))

    # Rounded square (macOS icon grid: 824 x 824 inside 1024, corner radius about 185).
    box = [sc(100), sc(100), sc(924), sc(924)]
    mask = Image.new("L", (N, N), 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, radius=sc(185), fill=255)

    # Soft shadow under it.
    shadow = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle([box[0], box[1] + sc(12), box[2], box[3] + sc(12)],
                                             radius=sc(185), fill=(0, 0, 0, 110))
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(sc(14))))

    bg = gradient(N, (40, 56, 98), (14, 19, 38))
    canvas.paste(bg, (0, 0), mask)

    d = ImageDraw.Draw(canvas)
    cx, cy = sc(512), sc(512)
    r_out, width = sc(280), sc(78)
    ring = [cx - r_out, cy - r_out, cx + r_out, cy + r_out]

    # Track (free space), drawn on its own layer so it blends with the background.
    track = Image.new("RGBA", (N, N), (0, 0, 0, 0))
    ImageDraw.Draw(track).ellipse(ring, outline=(255, 255, 255, 40), width=width)
    canvas.alpha_composite(track)

    # Used space by category, starting at the top and going clockwise.
    parts = [(0.36, (64, 156, 255)),   # blue
             (0.20, (175, 110, 255)),  # purple
             (0.14, (255, 159, 64)),   # orange
             (0.10, (72, 210, 140))]   # green
    gap = 3.0
    start = -90.0
    for share, color in parts:
        sweep = share * 360
        d.arc(ring, start + gap / 2, start + sweep - gap / 2, fill=color + (255,), width=width)
        start += sweep

    # Three rising bars in the middle: AI token use.
    bw, space, base = sc(58), sc(26), sc(612)
    heights = [sc(110), sc(170), sc(230)]
    x0 = cx - (3 * bw + 2 * space) // 2
    for i, h in enumerate(heights):
        x = x0 + i * (bw + space)
        shade = 200 + i * 27
        d.rounded_rectangle([x, base - h, x + bw, base], radius=sc(16), fill=(shade, shade, 255, 255))

    return canvas.resize((1024, 1024), Image.LANCZOS)


def main():
    icon = draw()
    out_dir = ROOT / "Resources" / "Icon"
    out_dir.mkdir(parents=True, exist_ok=True)
    icon.save(out_dir / "AppIcon-1024.png")
    sizes = [(16, 16), (32, 32), (64, 64), (128, 128), (256, 256), (512, 512), (1024, 1024)]
    icon.save(ROOT / "Resources" / "AppIcon.icns", sizes=sizes)
    print("Wrote", out_dir / "AppIcon-1024.png", "and", ROOT / "Resources" / "AppIcon.icns")


if __name__ == "__main__":
    main()
