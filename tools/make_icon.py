"""Draws the AuctionatorSync icon: a bronze gavel on its sound block, with a blue sync badge
(two circling arrows) in the bottom-right corner. Original artwork, transparent background.

Drawn at 1024 px and scaled down.
Run:  python tools/make_icon.py
  -> Images/Icon.tga (128, in-game AddOns list), icon.ico (DrangedAddons manager),
     tools/icon_preview.png (dark and light backgrounds)
"""
import math, os
from PIL import Image, ImageDraw, ImageFilter

S = 1024
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def lerp(a, b, t):
    t = max(0.0, min(1.0, t))
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(len(a)))


def bands(t, stops):
    """Colour at t (0..1) through a list of (position, colour) stops."""
    for (p0, c0), (p1, c1) in zip(stops, stops[1:]):
        if t <= p1:
            return lerp(c0, c1, (t - p0) / max(1e-6, p1 - p0))
    return stops[-1][1]


# Round-object shading across a cylinder: dark rim, warm body, bright highlight near the top.
BRONZE = [(0.0, (70, 30, 12, 255)), (0.18, (190, 110, 55, 255)), (0.30, (245, 185, 120, 255)),
          (0.45, (165, 85, 38, 255)), (0.80, (105, 48, 20, 255)), (1.0, (50, 20, 8, 255))]
GOLD = [(0.0, (120, 80, 10, 255)), (0.18, (240, 200, 70, 255)), (0.30, (255, 245, 180, 255)),
        (0.45, (230, 175, 40, 255)), (0.80, (170, 110, 15, 255)), (1.0, (95, 60, 5, 255))]
CAP_BRONZE = (215, 140, 80, 255)


def cylinder(length, dia, stops, cap=None, cap_w=0.32, bands_at=()):
    """A horizontal cylinder (local coords) with an end cap on the right; returns RGBA."""
    capw = int(dia * cap_w) if cap else 0
    img = Image.new("RGBA", (length + capw, dia), (0, 0, 0, 0))
    body = Image.new("RGBA", (length, dia))
    d = ImageDraw.Draw(body)
    for y in range(dia):
        d.line([(0, y), (length, y)], fill=bands(y / (dia - 1), stops))
    # optional gold bands (start, end) as fractions of the length
    for b0, b1 in bands_at:
        x0, x1 = int(length * b0), int(length * b1)
        gb = Image.new("RGBA", (x1 - x0, dia))
        gd = ImageDraw.Draw(gb)
        for y in range(dia):
            gd.line([(0, y), (x1 - x0, y)], fill=bands(y / (dia - 1), GOLD))
        body.paste(gb, (x0, 0))
    mask = Image.new("L", (length + capw, dia), 0)
    md = ImageDraw.Draw(mask)
    md.rectangle((capw // 2, 0, length, dia - 1), fill=255)
    md.ellipse((0, 0, capw, dia - 1), fill=255)  # rounded far end
    img.paste(body, (capw // 2, 0), mask.crop((capw // 2, 0, length + capw // 2, dia)))
    left = Image.new("RGBA", (capw, dia))
    ImageDraw.Draw(left).ellipse((0, 0, capw - 1, dia - 1), fill=bands(0.55, stops))
    img.alpha_composite(left, (0, 0))
    if cap:
        cp = Image.new("RGBA", (capw, dia), (0, 0, 0, 0))
        cd = ImageDraw.Draw(cp)
        cd.ellipse((0, 0, capw - 1, dia - 1), fill=lerp(cap, (60, 25, 10, 255), 0.35))
        cd.ellipse((int(capw * 0.12), int(dia * 0.06), int(capw * 0.9), int(dia * 0.9)), fill=cap)
        cd.ellipse((int(capw * 0.25), int(dia * 0.15), int(capw * 0.6), int(dia * 0.45)),
                   fill=lerp(cap, (255, 235, 200, 255), 0.5))
        img.alpha_composite(cp.filter(ImageFilter.GaussianBlur(2)), (length, 0))
    return img


def place(canvas, piece, center, angle):
    rot = piece.rotate(angle, resample=Image.BICUBIC, expand=True)
    canvas.alpha_composite(rot, (int(center[0] - rot.width / 2), int(center[1] - rot.height / 2)))


def drop_shadow(canvas, layer, offset=(14, 18), blur=18, alpha=110):
    a = layer.getchannel("A").filter(ImageFilter.GaussianBlur(blur)).point(lambda v: v * alpha // 255)
    sh = Image.new("RGBA", layer.size, (0, 0, 0, 0))
    sh.putalpha(a)
    canvas.alpha_composite(sh, offset)


def sound_block(layer):
    d = ImageDraw.Draw(layer)
    cx, top, w, h, depth = 360, 800, 560, 150, 70
    # side
    side = Image.new("RGBA", (w, depth + h // 2))
    sd = ImageDraw.Draw(side)
    for x in range(w):
        sd.line([(x, 0), (x, depth + h)], fill=bands(abs(x / (w - 1) - 0.35) * 1.4, BRONZE[1:]))
    m = Image.new("L", side.size, 0)
    ImageDraw.Draw(m).rectangle((0, 0, w, depth), fill=255)
    ImageDraw.Draw(m).ellipse((0, depth - h // 2, w - 1, depth + h // 2 - 1), fill=255)
    layer.paste(side, (cx - w // 2, top + h // 2), m)
    # top face
    d.ellipse((cx - w // 2, top, cx + w // 2, top + h), fill=(170, 95, 45, 255))
    d.ellipse((cx - w // 2 + 40, top + 18, cx + w // 2 - 40, top + h - 22), fill=(200, 125, 65, 255))
    d.ellipse((cx - w // 2 + 110, top + 38, cx + w // 2 - 170, top + h - 70), fill=(225, 160, 100, 255))


def arrow_arc(d, c, r, a0, a1, width, fill):
    """Thick arc from a0 to a1 degrees (clockwise in screen space) with an arrowhead at a1."""
    cx, cy = c
    d.arc((cx - r, cy - r, cx + r, cy + r), a0, a1 - 8, fill=fill, width=width)
    t = math.radians(a1)
    tip = (cx + r * math.cos(t), cy + r * math.sin(t))
    tang = (-math.sin(t), math.cos(t))       # direction of travel (clockwise)
    norm = (math.cos(t), math.sin(t))
    back = 0.9 * width * 1.6
    base = (tip[0] - tang[0] * back, tip[1] - tang[1] * back)
    half = width * 1.15
    d.polygon([(tip[0] + tang[0] * width * 0.4, tip[1] + tang[1] * width * 0.4),
               (base[0] + norm[0] * half, base[1] + norm[1] * half),
               (base[0] - norm[0] * half, base[1] - norm[1] * half)], fill=fill)


def sync_badge(canvas):
    cx, cy, r = 770, 770, 230
    badge = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    bd = ImageDraw.Draw(badge)
    bd.ellipse((cx - r - 16, cy - r - 16, cx + r + 16, cy + r + 16), fill=(20, 20, 28, 255))   # dark outline
    for i in range(r, 0, -2):                                                                # blue dome
        t = 1 - i / r
        bd.ellipse((cx - i, cy - i - t * 30, cx + i, cy + i - t * 30),
                   fill=lerp((15, 70, 150, 255), (90, 175, 255, 255), t ** 0.8))
    bd.ellipse((cx - r + 6, cy - r + 6, cx + r - 6, cy + r - 6), outline=(170, 215, 255, 255), width=8)
    glossy = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(glossy).ellipse((cx - r * 0.7, cy - r * 0.92, cx + r * 0.7, cy - r * 0.05),
                                   fill=(255, 255, 255, 60))
    badge.alpha_composite(glossy.filter(ImageFilter.GaussianBlur(10)))
    arrows = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ad = ImageDraw.Draw(arrows)
    ar, aw = int(r * 0.58), int(r * 0.17)
    arrow_arc(ad, (cx, cy), ar, 200, 345, aw, (255, 255, 255, 255))   # top arrow, going right
    arrow_arc(ad, (cx, cy), ar, 20, 165, aw, (255, 255, 255, 255))    # bottom arrow, going left
    drop_shadow(badge, arrows, offset=(5, 7), blur=6, alpha=140)
    badge.alpha_composite(arrows)
    drop_shadow(canvas, badge, offset=(8, 12), blur=14, alpha=120)
    canvas.alpha_composite(badge)


def main():
    art = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    sound_block(art)
    # handle: from the head down to the right
    handle = cylinder(560, 78, BRONZE, cap=CAP_BRONZE, cap_w=0.45)
    place(art, handle, (560, 520), -32)
    # head: thick cylinder with two gold bands, across the handle
    head = cylinder(470, 230, BRONZE, cap=CAP_BRONZE, bands_at=((0.36, 0.64),))
    place(art, head, (330, 330), 58)

    out = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    drop_shadow(out, art)
    out.alpha_composite(art)
    sync_badge(out)

    os.makedirs(os.path.join(ROOT, "Images"), exist_ok=True)
    out.resize((128, 128), Image.LANCZOS).save(os.path.join(ROOT, "Images", "Icon.tga"))
    out.resize((256, 256), Image.LANCZOS).save(os.path.join(ROOT, "icon.ico"),
                                               sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
    # preview: on dark and light, at 256 / 64 / 32
    prev = Image.new("RGBA", (2 * (256 + 64 + 32 + 40), 256), (0, 0, 0, 0))
    for i, bg in enumerate(((30, 30, 34, 255), (235, 235, 235, 255))):
        x0 = i * (256 + 64 + 32 + 40)
        tile = Image.new("RGBA", (256 + 64 + 32 + 40, 256), bg)
        tile.alpha_composite(out.resize((256, 256), Image.LANCZOS), (0, 0))
        tile.alpha_composite(out.resize((64, 64), Image.LANCZOS), (266, 0))
        tile.alpha_composite(out.resize((32, 32), Image.LANCZOS), (340, 0))
        prev.alpha_composite(tile, (x0, 0))
    prev.save(os.path.join(HERE, "icon_preview.png"))
    print("ok")


if __name__ == "__main__":
    main()
