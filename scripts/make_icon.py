"""Generates the Sanad AI app icon (1024x1024, opaque). Requires Pillow.

Design: deep Saudi-green gradient, an eight-pointed star (Islamic geometry)
outline, and a glowing core dot that reads as an on-device "mind".
"""
import math
import os
import sys

from PIL import Image, ImageDraw, ImageFilter

S = 1024
SS = 4  # supersampling
W = S * SS

out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    os.path.dirname(__file__), "..", "App", "Resources", "Assets.xcassets",
    "AppIcon.appiconset", "icon-1024.png")

img = Image.new("RGB", (W, W))
px = img.load()
top = (0, 92, 58)      # #005C3A
bottom = (0, 40, 30)   # #00281E
for y in range(W):
    t = y / (W - 1)
    c = tuple(int(top[i] * (1 - t) + bottom[i] * t) for i in range(3))
    for x in range(W):
        px[x, y] = c

d = ImageDraw.Draw(img)
cx = cy = W / 2


def star(r_out, r_in, rot=0.0):
    pts = []
    for k in range(16):
        r = r_out if k % 2 == 0 else r_in
        a = rot + k * math.pi / 8 - math.pi / 2
        pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return pts


gold = (212, 175, 55)
# Outer eight-pointed star made of two rotated squares
for rot in (0, math.pi / 4):
    sq = []
    for k in range(4):
        a = rot + k * math.pi / 2 - math.pi / 4
        sq.append((cx + 0.36 * W * math.cos(a), cy + 0.36 * W * math.sin(a)))
    d.polygon(sq, outline=gold, width=int(0.022 * W))

# Inner circle ring
r = 0.17 * W
d.ellipse((cx - r, cy - r, cx + r, cy + r), outline=(255, 255, 255), width=int(0.02 * W))

# Glow core
glow = Image.new("RGB", (W, W), (0, 0, 0))
gd = ImageDraw.Draw(glow)
gr = 0.09 * W
gd.ellipse((cx - gr, cy - gr, cx + gr, cy + gr), fill=(120, 255, 190))
glow = glow.filter(ImageFilter.GaussianBlur(0.05 * W))
img = Image.blend(img, Image.composite(glow, img, glow.convert("L")), 0.85)
d = ImageDraw.Draw(img)
cr = 0.055 * W
d.ellipse((cx - cr, cy - cr, cx + cr, cy + cr), fill=(255, 255, 255))

img = img.resize((S, S), Image.LANCZOS)
os.makedirs(os.path.dirname(out), exist_ok=True)
img.save(out, "PNG")
print("wrote", out)
