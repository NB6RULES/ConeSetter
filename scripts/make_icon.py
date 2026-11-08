"""Generates the app icon (1024x1024 PNG) used by Xcode and the SideStore source."""
import math
import sys
from PIL import Image, ImageDraw, ImageFilter

S = 1024
SS = 4  # supersample
W = S * SS


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def main(out_paths):
    img = Image.new("RGB", (W, W))
    d = ImageDraw.Draw(img)
    top, bottom = (28, 31, 38), (10, 11, 14)
    for y in range(W):
        d.line([(0, y), (W, y)], fill=lerp(top, bottom, y / W))

    cx = W // 2
    base_y = int(W * 0.74)

    # AR target ring on the ground (ellipse, dashed) + glow
    glow = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    gd = ImageDraw.Draw(glow)
    rx, ry = int(W * 0.36), int(W * 0.105)
    gd.ellipse([cx - rx, base_y - ry, cx + rx, base_y + ry], outline=(0, 220, 255, 150), width=int(W * 0.018))
    glow = glow.filter(ImageFilter.GaussianBlur(W * 0.012))
    img.paste(glow, (0, 0), glow)

    d = ImageDraw.Draw(img)
    dashes = 28
    for i in range(dashes):
        a0 = 2 * math.pi * i / dashes
        a1 = a0 + 2 * math.pi / dashes * 0.55
        pts = [(cx + rx * math.cos(a), base_y + ry * math.sin(a)) for a in [a0 + (a1 - a0) * k / 8 for k in range(9)]]
        d.line(pts, fill=(90, 235, 255), width=int(W * 0.011))

    # small blue / yellow cones in the distance
    def cone(x, y, h, w, body, band=True, shadow=True):
        if shadow:
            d.ellipse([x - w * 0.75, y - h * 0.05, x + w * 0.75, y + h * 0.07], fill=(6, 6, 8))
        base_h = h * 0.07
        d.rectangle([x - w * 0.62, y - base_h, x + w * 0.62, y], fill=tuple(max(0, c - 70) for c in body))
        d.polygon([(x - w * 0.46, y - base_h), (x + w * 0.46, y - base_h), (x + w * 0.07, y - h), (x - w * 0.07, y - h)], fill=body)
        if band:
            t0, t1 = 0.42, 0.62
            def at(t):
                yy = y - base_h - (h - base_h) * t
                half = w * 0.46 - (w * 0.46 - w * 0.07) * t
                return yy, half
            y0, h0 = at(t0)
            y1, h1 = at(t1)
            d.polygon([(x - h0, y0), (x + h0, y0), (x + h1, y1), (x - h1, y1)], fill=(245, 245, 245))

    cone(int(W * 0.19), int(W * 0.60), W * 0.16, W * 0.12, (35, 110, 255))
    cone(int(W * 0.81), int(W * 0.60), W * 0.16, W * 0.12, (255, 212, 20))

    # main orange cone
    cone(cx, base_y, W * 0.56, W * 0.40, (255, 106, 18))

    # crosshair corners
    m, L, t = int(W * 0.09), int(W * 0.12), int(W * 0.014)
    col = (255, 255, 255)
    for (x, y, sx, sy) in [(m, m, 1, 1), (W - m, m, -1, 1), (m, W - m, 1, -1), (W - m, W - m, -1, -1)]:
        d.rectangle([min(x, x + sx * L), min(y, y + sy * t), max(x, x + sx * L), max(y, y + sy * t)], fill=col)
        d.rectangle([min(x, x + sx * t), min(y, y + sy * L), max(x, x + sx * t), max(y, y + sy * L)], fill=col)

    out = img.resize((S, S), Image.LANCZOS)
    for p in out_paths:
        out.save(p, "PNG")


if __name__ == "__main__":
    main(sys.argv[1:])
