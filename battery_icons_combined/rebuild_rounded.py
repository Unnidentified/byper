# Regenerates the menu-bar battery icon set with a rounder, constant corner radius:
# border ring and inner fill both use RADIUS (2x units) — "constant across fill and border".
# Geometry (2x units, canvas 50x28) measured from the original set:
#   body ring outer box [0,2,45,25], stroke 2px @ alpha 64, old outer radius ~5.0
#   terminal nub box [46,10,48,17], radius ~1.5, alpha 92
#   fill rect x 4..41, y 6..21, old fill radius 3.5
# Badge overlays (bolt / plug / alert '!' / missing 'X') are copied pixel-exact from the
# previous 0% / missing frames (region x 12..34), so their design is untouched.
import os, re
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

RADIUS = 8.0          # border ring outer radius (2x units)
FILL_RADIUS = 4.0     # fill radius = RADIUS - 4 (uniform 4px inset) -> concentric corners
RING_ALPHA = 64
NUB_ALPHA = 92
BASE_W, BASE_H = 50, 28

DARK = dict(red=(255, 69, 58), orange=(255, 159, 10), green=(48, 209, 88))
WHITE = (255, 255, 255)

DIRS = [
    "/Users/gefaass/Desktop/addon-modules/working/macos-ch.bypass #2/src/app/icons_highres",   # 150x84 (3x) — bundled
    "/Users/gefaass/Desktop/addon-modules/working/macos-ch.bypass #2/battery_icons_combined/standard/dark/2x",  # 50x28 — fallback/preview
]
# badge regions are always taken from the untouched originals in the fresh copy
SRC_ROOT = "/Users/gefaass/Desktop/addon-modules/working/macos-ch.bypass #3"

def parse_name(fn):
    m = re.match(r"battery_(missing|charging_(\d+)|plugged_(\d+)|alert_(\d+)|(\d+))@2x\.png$", fn)
    if not m:
        return None
    if m.group(1) == "missing":
        return ("missing", 0)
    if m.group(2) is not None:
        return ("charging", int(m.group(2)))
    if m.group(3) is not None:
        return ("plugged", int(m.group(3)))
    if m.group(4) is not None:
        return ("alert", int(m.group(4)))
    return ("normal", int(m.group(5)))

def fill_color(pct):
    if pct <= 20:
        return DARK["red"] + (255,)
    if pct <= 50:
        return DARK["orange"] + (255,)
    return DARK["green"] + (255,)

def draw_frame(k, badge_src):
    """Redrawn ring + nub at scale k (k=3 -> 150x84), badge region pasted from old frame."""
    w, h = BASE_W * k, BASE_H * k
    ss = 8
    img = Image.new("RGBA", (w * ss, h * ss), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    ring = WHITE + (RING_ALPHA,)
    # body ring: box [0,2,46,26] in 2x units — PIL strokes grow INWARD from the box
    # edges, so +1 on x1/y1 puts the 2px stroke exactly on cols 0-1/44-45, rows 2-3/24-25
    d.rounded_rectangle([0 * k * ss, 2 * k * ss, 46 * k * ss, 26 * k * ss],
                        radius=RADIUS * k * ss,
                        outline=ring, width=max(1, round(2 * k * ss)))
    # terminal nub
    d.rounded_rectangle([46 * k * ss, 10 * k * ss, 48 * k * ss, 17 * k * ss],
                        radius=1.5 * k * ss,
                        fill=WHITE + (NUB_ALPHA,))
    frame = img.resize((w, h), Image.Resampling.LANCZOS)
    # replace (not over-composite) the badge zone with the old frame pixels — brings the
    # badge glyphs and their border cutouts without doubling the straight-border opacity
    bx = (12 * k, 34 * k)
    region = badge_src.crop((bx[0], 0, bx[1], h))
    frame.paste(region, (bx[0], 0))
    return frame

def draw_fill(k, pct, color):
    """Radius-conforming inner fill (same RADIUS as the border), 8x supersampled."""
    w, h = BASE_W * k, BASE_H * k
    x0, x1_max, y0, y1 = 4 * k, 41 * k, 6 * k, 21 * k
    max_w = x1_max - x0 + 1
    fw = int(round(max_w * (pct / 100.0)))
    fw = max(fw, 4 * k)  # minimal visible sliver (red) below 10%, including 0%
    fx1 = x0 + fw - 1
    ss = 8
    img = Image.new("RGBA", (w * ss, h * ss), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    max_r = min(FILL_RADIUS * k, (fx1 - x0 + 1) / 2.0, (y1 - y0 + 1) / 2.0)
    d.rounded_rectangle([x0 * ss, y0 * ss, (fx1 + 1) * ss - 1, (y1 + 1) * ss - 1],
                        radius=max_r * ss, fill=color)
    return img.resize((w, h), Image.Resampling.LANCZOS)

def cutout_badge(fill, old_frame, k):
    """Clear the badge zone out of the fill (same dilation logic as build_icons.py)."""
    w, h = fill.size
    arr = np.array(old_frame)
    bx0, bx1 = 12 * k, 34 * k
    mask = np.zeros((h, w), dtype=np.uint8)
    mask[:, bx0:bx1] = arr[:, bx0:bx1, 3]
    fsize = 5 * k
    if fsize % 2 == 0:
        fsize += 1
    m = np.array(Image.fromarray(mask).filter(ImageFilter.MaxFilter(fsize))) / 255.0
    out = np.array(fill)
    out[:, :, 3] = (out[:, :, 3] * (1.0 - m)).astype(np.uint8)
    return Image.fromarray(out, mode="RGBA")

for out_dir in DIRS:
    src_dir = out_dir.replace("macos-ch.bypass #2", "macos-ch.bypass #3")
    files = sorted(f for f in os.listdir(out_dir) if f.endswith(".png"))
    frames = {}
    for fn in files:
        parsed = parse_name(fn)
        if parsed and parsed[1] == 0:
            frames[parsed[0]] = Image.open(os.path.join(src_dir, fn)).convert("RGBA")
    if "normal" not in frames:
        print("skip", out_dir)
        continue
    k = Image.open(os.path.join(out_dir, files[0])).size[0] // BASE_W
    print(f"{out_dir}  scale x{k}  files={len(files)}")
    for fn in files:
        parsed = parse_name(fn)
        if not parsed:
            print("  unparsed:", fn)
            continue
        state, pct = parsed
        badge_src = frames.get(state)
        if badge_src is None:
            print("  no frame for", state, fn)
            continue
        canvas = draw_frame(k, badge_src)
        if state != "missing":
            fill = draw_fill(k, pct, fill_color(pct))
            if state in ("charging", "plugged"):
                fill = cutout_badge(fill, badge_src, k)
            canvas = Image.alpha_composite(fill, canvas)
        canvas.save(os.path.join(out_dir, fn))
    print("  done")
print("rebuilt with constant radius", RADIUS)
