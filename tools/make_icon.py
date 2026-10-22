"""Builds the AuctionatorSync icon from a game icon (same process as CraftRoute's).

Source: Wowhead's 56x56 copy of the game icon inv_misc_coin_02
  https://wow.zamimg.com/images/wow/icons/large/inv_misc_coin_02.jpg

Lanczos upscale to 64x64 plus a light unsharp mask -> Images/Icon.tga (addon list, minimap button,
options page); icon.ico (DrangedAddons manager) holds 64/48/32/16 px from the same image.

Run:  python tools/make_icon.py <path to the downloaded 56px jpg>
"""
import os
import sys
from PIL import Image, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)


def main(src):
    im = Image.open(src).convert("RGB")
    big = im.resize((64, 64), Image.LANCZOS)
    # RGBA throughout: the .ico header says 32-bit, and WPF (the manager) refuses 24-bit PNG
    # entries inside a 32-bit icon
    big = big.filter(ImageFilter.UnsharpMask(radius=1.0, percent=60, threshold=2)).convert("RGBA")
    os.makedirs(os.path.join(ROOT, "Images"), exist_ok=True)
    big.save(os.path.join(ROOT, "Images", "Icon.tga"))
    big.save(os.path.join(ROOT, "icon.ico"), sizes=[(64, 64), (48, 48), (32, 32), (16, 16)])
    print("ok", im.size, "->", big.size)


if __name__ == "__main__":
    main(sys.argv[1])
