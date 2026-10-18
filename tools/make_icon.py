"""Draws the AuctionatorSync icon: a goblin auctioneer behind his podium, gavel raised.

Painted WoW-icon look built from layered gradients, drawn at 4x and scaled down.
Run:  python tools/make_icon.py   ->  Images/Icon.tga (128, in-game), icon.ico (manager), tools/icon_preview.png
"""
import math, os
from PIL import Image, ImageDraw, ImageFilter, ImageChops

S = 1024  # working size
HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(len(a)))


def radial(size, center, radius, inner, outer):
    img = Image.new("RGBA", size)
    px = img.load()
    cx, cy = center
    for y in range(size[1]):
        for x in range(size[0]):
            d = min(1.0, math.hypot(x - cx, y - cy) / radius)
            px[x, y] = lerp(inner, outer, d ** 1.2)
    return img


def vgrad(size, top, bottom):
    img = Image.new("RGBA", size)
    d = ImageDraw.Draw(img)
    for y in range(size[1]):
        d.line([(0, y), (size[0], y)], fill=lerp(top, bottom, y / max(1, size[1] - 1)))
    return img


def shape_mask(draw_fn):
    m = Image.new("L", (S, S), 0)
    d = ImageDraw.Draw(m)
    d.fill, d.ink = True, 255  # shapes drawn without fill= come out solid, not as outlines
    draw_fn(d)
    return m


def paint(base, fill_img, mask, blur=0):
    if blur:
        mask = mask.filter(ImageFilter.GaussianBlur(blur))
    base.alpha_composite(Image.composite(fill_img, Image.new("RGBA", (S, S), (0, 0, 0, 0)), mask))


def shade(base, mask, light_from=(-1, -1), strength=90, width=60, color=(0, 0, 0)):
    """Darken the side of a shape away from the light (soft inner shadow)."""
    dx, dy = light_from
    shifted = ImageChops.offset(mask, int(-dx * width), int(-dy * width))
    rim = ImageChops.subtract(mask, shifted).filter(ImageFilter.GaussianBlur(width * 0.6))
    rim = ImageChops.multiply(rim, mask)
    layer = Image.new("RGBA", (S, S), color + (0,))
    layer.putalpha(rim.point(lambda v: v * strength // 255))
    base.alpha_composite(layer)


def highlight(base, mask, light_from=(-1, -1), strength=110, width=40, color=(255, 240, 200)):
    shade(base, mask, light_from=(-light_from[0], -light_from[1]), strength=strength, width=width, color=color)


def rotated_rect(cx, cy, w, h, angle_deg):
    a = math.radians(angle_deg)
    ca, sa = math.cos(a), math.sin(a)
    pts = []
    for x, y in ((-w / 2, -h / 2), (w / 2, -h / 2), (w / 2, h / 2), (-w / 2, h / 2)):
        pts.append((cx + x * ca - y * sa, cy + x * sa + y * ca))
    return pts


def main():
    img = Image.new("RGBA", (S, S), (0, 0, 0, 255))

    # --- background: warm auction-hall glow behind the figure, dark edges
    small = radial((256, 256), (128, 95), 190, (150, 70, 25, 255), (18, 8, 6, 255))
    img.alpha_composite(small.resize((S, S), Image.BICUBIC))
    # faint gold light rays from behind
    rays = Image.new("L", (S, S), 0)
    rd = ImageDraw.Draw(rays)
    for i in range(14):
        a = math.radians(i * (360 / 14) + 7)
        rd.polygon([(512, 380), (512 + 900 * math.cos(a - 0.07), 380 + 900 * math.sin(a - 0.07)),
                    (512 + 900 * math.cos(a + 0.07), 380 + 900 * math.sin(a + 0.07))], fill=40)
    paint(img, Image.new("RGBA", (S, S), (255, 200, 90, 255)), rays, blur=25)

    # --- body (dark suit with gold-trimmed vest) behind the podium
    body = shape_mask(lambda d: d.ellipse((250, 520, 790, 1100)))
    paint(img, vgrad((S, S), (60, 40, 70, 255), (20, 12, 25, 255)), body)
    vest = shape_mask(lambda d: d.polygon([(440, 560), (600, 560), (560, 800), (480, 800)]))
    paint(img, vgrad((S, S), (150, 30, 30, 255), (70, 10, 12, 255)), vest)
    collar = shape_mask(lambda d: (d.polygon([(450, 555), (512, 640), (420, 620)]),
                                   d.polygon([(590, 555), (512, 640), (620, 620)])))
    paint(img, Image.new("RGBA", (S, S), (235, 225, 205, 255)), collar)
    shade(img, body, light_from=(-1, -1), strength=150, width=70)

    # --- raised arm (his right, our left) holding the gavel up
    arm = shape_mask(lambda d: d.polygon([(330, 600), (410, 650), (300, 330), (225, 360)]))
    paint(img, vgrad((S, S), (70, 48, 80, 255), (30, 18, 35, 255)), arm)
    shade(img, arm, light_from=(1, -1), strength=120, width=40)
    cuff = shape_mask(lambda d: d.polygon([(220, 355), (305, 325), (318, 362), (232, 395)]))
    paint(img, Image.new("RGBA", (S, S), (230, 215, 190, 255)), cuff)
    hand = shape_mask(lambda d: d.ellipse((215, 255, 320, 350)))
    skin = vgrad((S, S), (150, 200, 90, 255), (60, 110, 40, 255))
    paint(img, skin, hand)
    shade(img, hand, light_from=(-1, -1), strength=140, width=25)

    # gavel: handle up-left from the hand, head across the top
    handle = shape_mask(lambda d: d.polygon(rotated_rect(225, 205, 34, 210, -28)))
    paint(img, vgrad((S, S), (170, 110, 55, 255), (90, 50, 20, 255)), handle)
    shade(img, handle, light_from=(-1, 0), strength=120, width=12)
    head = shape_mask(lambda d: d.polygon(rotated_rect(178, 112, 210, 92, -28)))
    paint(img, vgrad((S, S), (140, 80, 35, 255), (60, 30, 10, 255)), head)
    bands = shape_mask(lambda d: (d.polygon(rotated_rect(108, 149, 22, 96, -28)),
                                  d.polygon(rotated_rect(248, 75, 22, 96, -28))))
    paint(img, vgrad((S, S), (255, 220, 110, 255), (170, 110, 30, 255)), bands)
    highlight(img, head, light_from=(-1, -1), strength=120, width=18)
    shade(img, head, light_from=(-1, -1), strength=140, width=22)
    # motion arcs: swinging around the hand, trailing outside the gavel head
    px_, py_ = 268, 302
    arcs = shape_mask(lambda d: [d.arc((px_ - r, py_ - r, px_ + r, py_ + r), 222, 262, fill=255, width=12)
                                 for r in (300, 340, 380)])
    paint(img, Image.new("RGBA", (S, S), (255, 235, 170, 255)), arcs, blur=3)

    # --- goblin head: big ears, green skin, top hat
    ears = shape_mask(lambda d: (d.polygon([(400, 410), (250, 330), (410, 470)]),
                                 d.polygon([(625, 410), (790, 320), (615, 475)])))
    paint(img, skin, ears)
    shade(img, ears, light_from=(-1, -1), strength=150, width=30)
    inner_ears = shape_mask(lambda d: (d.polygon([(395, 425), (300, 360), (400, 455)]),
                                       d.polygon([(630, 425), (740, 350), (622, 458)])))
    paint(img, Image.new("RGBA", (S, S), (90, 120, 50, 255)), inner_ears, blur=4)
    face = shape_mask(lambda d: d.ellipse((385, 330, 640, 590)))
    paint(img, skin, face)
    shade(img, face, light_from=(-1, -1), strength=160, width=60)
    highlight(img, face, light_from=(-1, -1), strength=70, width=25)
    nose = shape_mask(lambda d: d.polygon([(505, 430), (560, 500), (500, 505)]))
    paint(img, vgrad((S, S), (130, 180, 75, 255), (60, 100, 35, 255)), nose)
    shade(img, nose, light_from=(-1, -1), strength=150, width=14)
    eyes = shape_mask(lambda d: (d.ellipse((440, 425, 482, 455)), d.ellipse((540, 425, 582, 455))))
    paint(img, Image.new("RGBA", (S, S), (255, 230, 80, 255)), eyes)
    pupils = shape_mask(lambda d: (d.ellipse((455, 430, 472, 452)), d.ellipse((555, 430, 572, 452))))
    paint(img, Image.new("RGBA", (S, S), (20, 10, 5, 255)), pupils)
    brows = shape_mask(lambda d: (d.line([(430, 418), (488, 428)], fill=255, width=12),
                                  d.line([(534, 428), (592, 418)], fill=255, width=12)))
    paint(img, Image.new("RGBA", (S, S), (40, 50, 20, 255)), brows)
    grin = shape_mask(lambda d: d.chord((455, 470, 585, 560), 10, 170, fill=255))
    paint(img, Image.new("RGBA", (S, S), (40, 15, 10, 255)), grin)
    teeth = shape_mask(lambda d: d.rectangle((478, 512, 562, 527)))
    paint(img, Image.new("RGBA", (S, S), (240, 235, 210, 255)), ImageChops.multiply(teeth, grin))
    # top hat
    hat = shape_mask(lambda d: (d.rectangle((430, 190, 595, 345)), d.ellipse((380, 320, 645, 370))))
    paint(img, vgrad((S, S), (50, 40, 55, 255), (12, 8, 14, 255)), hat)
    band = shape_mask(lambda d: d.rectangle((430, 300, 595, 335)))
    paint(img, vgrad((S, S), (180, 30, 30, 255), (90, 10, 10, 255)), band)
    shade(img, hat, light_from=(-1, -1), strength=150, width=30)
    highlight(img, hat, light_from=(-1, -1), strength=60, width=14)

    # --- podium: carved wood with gold trim and a coin emblem
    podium = shape_mask(lambda d: d.polygon([(215, 700), (810, 700), (760, 1024), (265, 1024)]))
    paint(img, vgrad((S, S), (150, 85, 40, 255), (55, 28, 12, 255)), podium)
    planks = shape_mask(lambda d: [d.line([(x, 720), (x + (512 - x) * 0.08, 1024)], fill=255, width=6)
                                   for x in range(300, 760, 80)])
    paint(img, Image.new("RGBA", (S, S), (40, 18, 6, 255)), ImageChops.multiply(planks, podium), blur=2)
    shade(img, podium, light_from=(-1, -1), strength=170, width=70)
    top = shape_mask(lambda d: d.polygon([(185, 660), (840, 660), (825, 720), (200, 720)]))
    paint(img, vgrad((S, S), (255, 215, 110, 255), (150, 95, 25, 255)), top)
    highlight(img, top, light_from=(0, -1), strength=150, width=10)
    shade(img, top, light_from=(0, -1), strength=120, width=12)
    coin = shape_mask(lambda d: d.ellipse((430, 770, 594, 934)))
    paint(img, radial((S, S), (490, 820), 120, (255, 235, 140, 255), (170, 105, 20, 255)), coin)
    coin_in = shape_mask(lambda d: d.ellipse((462, 802, 562, 902)))
    shade(img, coin_in, light_from=(1, 1), strength=150, width=12)
    shade(img, coin, light_from=(-1, -1), strength=120, width=16)

    # --- icon finish: vignette and a thin dark bevel like the game's icons
    vig = Image.new("L", (S, S), 0)
    ImageDraw.Draw(vig).rectangle((0, 0, S, S), outline=255, width=70)
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    layer.putalpha(vig.filter(ImageFilter.GaussianBlur(60)).point(lambda v: v * 200 // 255))
    img.alpha_composite(layer)
    ImageDraw.Draw(img).rectangle((0, 0, S - 1, S - 1), outline=(10, 6, 4, 255), width=10)

    img = img.convert("RGB")
    os.makedirs(os.path.join(ROOT, "Images"), exist_ok=True)
    img.resize((512, 512), Image.LANCZOS).save(os.path.join(HERE, "icon_preview.png"))
    img.resize((128, 128), Image.LANCZOS).convert("RGBA").save(os.path.join(ROOT, "Images", "Icon.tga"))
    img.resize((256, 256), Image.LANCZOS).save(os.path.join(ROOT, "icon.ico"),
                                               sizes=[(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)])
    print("ok")


if __name__ == "__main__":
    main()
