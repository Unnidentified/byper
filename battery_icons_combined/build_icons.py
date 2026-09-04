import os
import shutil
from PIL import Image, ImageDraw, ImageFont, ImageFilter
import numpy as np

OUTPUT_DIR = "/Users/gefaass/Desktop/battery_icons_combined"
ASSETS_DIR = os.path.join(OUTPUT_DIR, "base_assets")

FONT_PATH = "/System/Library/Fonts/Supplemental/Arial.ttf"
if not os.path.exists(FONT_PATH):
    FONT_PATH = "/System/Library/Fonts/Helvetica.ttc"

def get_font(size):
    try:
        return ImageFont.truetype(FONT_PATH, size)
    except:
        return ImageFont.load_default()

def colorize(img, rgb_color):
    arr = np.array(img.convert("RGBA"))
    arr[:, :, 0] = rgb_color[0]
    arr[:, :, 1] = rgb_color[1]
    arr[:, :, 2] = rgb_color[2]
    return Image.fromarray(arr, mode="RGBA")

def get_theme_colors(theme, pct, state):
    """
    Color variance thresholds:
      - <= 20%: Apple Red
      - 21% - 50%: Apple Orange / Amber (starts at 50% down to 20%)
      - > 50%: Apple Green (51% - 100%)
    """
    is_dark = "dark" in theme

    if is_dark:
        base_color = (255, 255, 255)
        red = (255, 69, 58)       # Apple Dark Mode Red
        orange = (255, 159, 10)   # Apple Dark Mode Orange
        green = (48, 209, 88)     # Apple Dark Mode Green
    else:
        base_color = (0, 0, 0)
        red = (255, 59, 48)       # Apple Light Mode Red
        orange = (255, 149, 0)    # Apple Light Mode Orange
        green = (52, 199, 89)     # Apple Light Green

    if theme in ("monochrome_light", "monochrome_dark"):
        fill_color = base_color
        badge_color = base_color
    else:
        # Dynamic percentage color variance: Red <= 20%, Orange 21-50%, Green > 50%
        if pct <= 20:
            fill_color = red
        elif pct <= 50:
            fill_color = orange
        else:
            fill_color = green

        if state == "alert":
            badge_color = orange
        elif state == "missing":
            badge_color = red
        else:
            badge_color = base_color

    return base_color, fill_color, badge_color

def draw_rounded_fill(canvas_w, canvas_h, x0, y0, x1_max, y1, pct, color, radius):
    """
    Renders an anti-aliased rounded rectangle inner fill matching the border radius.
    """
    max_w = x1_max - x0 + 1
    w = int(round(max_w * (pct / 100.0)))
    if w <= 0:
        return Image.new("RGBA", (canvas_w, canvas_h), (0, 0, 0, 0))
    
    fx1 = x0 + w - 1
    ss = 8
    sw, sh = canvas_w * ss, canvas_h * ss
    img_ss = Image.new("RGBA", (sw, sh), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img_ss)
    
    sx0 = x0 * ss
    sy0 = y0 * ss
    sx1 = (fx1 + 1) * ss - 1
    sy1 = (y1 + 1) * ss - 1
    
    # Effective radius conforms to border curvature, capped at half dimensions
    max_r = min(radius, (fx1 - x0 + 1) / 2.0, (y1 - y0 + 1) / 2.0)
    s_rad = max_r * ss
    
    draw.rounded_rectangle([sx0, sy0, sx1, sy1], radius=s_rad, fill=color + (255,))
    return img_ss.resize((canvas_w, canvas_h), Image.Resampling.LANCZOS)

def create_standard_battery(scale=1, pct=100, state="normal", theme="colored_dark"):
    canvas_w, canvas_h = (50, 28) if scale == 2 else (25, 14)
    fill_x0 = 4 if scale == 2 else 2
    fill_x1_max = 41 if scale == 2 else 20
    fill_y0 = 6 if scale == 2 else 3
    fill_y1 = 21 if scale == 2 else 10
    corner_radius = 3.5 if scale == 2 else 1.8

    base_color, fill_color, badge_color = get_theme_colors(theme, pct, state)

    # 1. Inner Fill Layer following border radius
    fill_img = Image.new("RGBA", (canvas_w, canvas_h), (0, 0, 0, 0))
    if pct > 0 and state != "missing":
        fill_img = draw_rounded_fill(canvas_w, canvas_h, fill_x0, fill_y0, fill_x1_max, fill_y1, pct, fill_color, corner_radius)

    # 2. Outline & Badge Layer
    if state == "charging":
        ref_file = f"standard_charging_0_{scale}x.png"
    elif state == "plugged":
        ref_file = f"standard_plugged_0_{scale}x.png"
    elif state == "alert":
        ref_file = f"standard_alert_0_{scale}x.png"
    elif state == "missing":
        ref_file = f"standard_missing_{scale}x.png"
    else:
        ref_file = f"standard_outline_{scale}x.png"

    raw_frame = Image.open(os.path.join(ASSETS_DIR, ref_file))
    frame_img = colorize(raw_frame, base_color if state not in ("alert", "missing") else badge_color)

    # 3. If overlay has cutout mask (charging or plugged), mask fill
    if state in ("charging", "plugged") and pct > 0:
        # Extract cutout mask from badge
        arr_frame = np.array(raw_frame)
        # Dilate badge area (x: 12..33 for 2x, 6..16 for 1x)
        badge_mask_arr = np.zeros((canvas_h, canvas_w), dtype=np.uint8)
        bx0, bx1 = (12, 34) if scale == 2 else (6, 17)
        badge_mask_arr[:, bx0:bx1] = arr_frame[:, bx0:bx1, 3]
        
        # MaxFilter to dilate mask for cutout clearance
        filter_size = 5 if scale == 2 else 3
        badge_mask_img = Image.fromarray(badge_mask_arr).filter(ImageFilter.MaxFilter(filter_size))
        m_alpha = np.array(badge_mask_img) / 255.0

        # Apply cutout to fill_img
        f_arr = np.array(fill_img)
        for r in range(canvas_h):
            for c in range(canvas_w):
                v = m_alpha[r, c]
                if v > 0:
                    f_arr[r, c, 3] = int(f_arr[r, c, 3] * (1.0 - v))
        fill_img = Image.fromarray(f_arr, mode="RGBA")

    # Combine Fill + Frame
    return Image.alpha_composite(fill_img, frame_img)

def create_compact_battery(scale=1, pct=100, state="normal", theme="colored_dark"):
    canvas_w, canvas_h = (42, 24) if scale == 2 else (21, 12)
    fill_x0 = 3 if scale == 2 else 2
    fill_x1_max = 34 if scale == 2 else 16
    fill_y0 = 5 if scale == 2 else 3
    fill_y1 = 18 if scale == 2 else 8
    corner_radius = 2.5 if scale == 2 else 1.2

    base_color, fill_color, badge_color = get_theme_colors(theme, pct, state)

    fill_img = Image.new("RGBA", (canvas_w, canvas_h), (0, 0, 0, 0))
    if pct > 0:
        fill_img = draw_rounded_fill(canvas_w, canvas_h, fill_x0, fill_y0, fill_x1_max, fill_y1, pct, fill_color, corner_radius)

    ref_file = f"compact_charging_0_{scale}x.png" if state == "charging" else f"compact_outline_{scale}x.png"
    raw_frame = Image.open(os.path.join(ASSETS_DIR, ref_file))
    frame_img = colorize(raw_frame, base_color)

    if state == "charging" and pct > 0:
        arr_frame = np.array(raw_frame)
        badge_mask_arr = np.zeros((canvas_h, canvas_w), dtype=np.uint8)
        bx0, bx1 = (10, 28) if scale == 2 else (5, 14)
        badge_mask_arr[:, bx0:bx1] = arr_frame[:, bx0:bx1, 3]
        
        filter_size = 5 if scale == 2 else 3
        badge_mask_img = Image.fromarray(badge_mask_arr).filter(ImageFilter.MaxFilter(filter_size))
        m_alpha = np.array(badge_mask_img) / 255.0

        f_arr = np.array(fill_img)
        for r in range(canvas_h):
            for c in range(canvas_w):
                v = m_alpha[r, c]
                if v > 0:
                    f_arr[r, c, 3] = int(f_arr[r, c, 3] * (1.0 - v))
        fill_img = Image.fromarray(f_arr, mode="RGBA")

    return Image.alpha_composite(fill_img, frame_img)

def create_ups_battery(scale=1, pct=100, state="normal", theme="colored_dark"):
    canvas_w, canvas_h = (24, 32) if scale == 2 else (12, 16)
    base_color, fill_color, badge_color = get_theme_colors(theme, pct, state)

    if state == "charging":
        img = Image.open(os.path.join(ASSETS_DIR, f"ups_charging_{scale}x.png"))
        return colorize(img, (48, 209, 88) if "dark" in theme else (52, 199, 89))
    elif state == "charged":
        img = Image.open(os.path.join(ASSETS_DIR, f"ups_charged_{scale}x.png"))
        return colorize(img, (48, 209, 88) if "dark" in theme else (52, 199, 89))

    empty_img = colorize(Image.open(os.path.join(ASSETS_DIR, f"ups_outline_{scale}x.png")), base_color)
    canvas = Image.new("RGBA", (canvas_w, canvas_h), (0, 0, 0, 0))

    num_slices = int(round(12 * (pct / 100.0)))
    
    if scale == 1:
        empty_y = 1
        slice_w, slice_h = 8, 1
        slice_x = 2
        bottom_y = 12
        step_y = 1
    else:
        empty_y = 2
        slice_w, slice_h = 16, 2
        slice_x = 4
        bottom_y = 24
        step_y = 2

    for i in range(num_slices):
        cur_y = bottom_y - (i * step_y)
        slice_pct = (i + 1) * (100 / 12.0)
        _, slice_col, _ = get_theme_colors(theme, int(slice_pct), state)
        
        lvl_img = Image.new("RGBA", (slice_w, slice_h), slice_col + (255,))
        canvas.paste(lvl_img, (slice_x, cur_y), lvl_img)

    canvas.paste(empty_img, (0, empty_y), empty_img)
    return canvas

def generate_all_assets():
    themes = [
        ("light", "Light Mode (Color Variance)"),
        ("dark", "Dark Mode (Color Variance)"),
        ("colored", "macOS System Colors (Light BG)"),
        ("colored_dark", "macOS System Colors (Dark BG)"),
        ("monochrome_light", "Monochrome Light (Pure Black)"),
        ("monochrome_dark", "Monochrome Dark (Pure White)")
    ]

    percentages = [0, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100]

    count = 0
    # 1. Standard Battery
    for theme_key, _ in themes:
        theme_dir_1x = os.path.join(OUTPUT_DIR, "standard", theme_key, "1x")
        theme_dir_2x = os.path.join(OUTPUT_DIR, "standard", theme_key, "2x")
        os.makedirs(theme_dir_1x, exist_ok=True)
        os.makedirs(theme_dir_2x, exist_ok=True)

        for p in percentages:
            im1 = create_standard_battery(scale=1, pct=p, state="normal", theme=theme_key)
            im2 = create_standard_battery(scale=2, pct=p, state="normal", theme=theme_key)
            im1.save(os.path.join(theme_dir_1x, f"battery_{p}.png"))
            im2.save(os.path.join(theme_dir_2x, f"battery_{p}@2x.png"))
            count += 2

        for p in percentages:
            im1 = create_standard_battery(scale=1, pct=p, state="charging", theme=theme_key)
            im2 = create_standard_battery(scale=2, pct=p, state="charging", theme=theme_key)
            im1.save(os.path.join(theme_dir_1x, f"battery_charging_{p}.png"))
            im2.save(os.path.join(theme_dir_2x, f"battery_charging_{p}@2x.png"))
            count += 2

        for p in percentages:
            im1 = create_standard_battery(scale=1, pct=p, state="plugged", theme=theme_key)
            im2 = create_standard_battery(scale=2, pct=p, state="plugged", theme=theme_key)
            im1.save(os.path.join(theme_dir_1x, f"battery_plugged_{p}.png"))
            im2.save(os.path.join(theme_dir_2x, f"battery_plugged_{p}@2x.png"))
            count += 2

        for p in percentages:
            im1 = create_standard_battery(scale=1, pct=p, state="alert", theme=theme_key)
            im2 = create_standard_battery(scale=2, pct=p, state="alert", theme=theme_key)
            im1.save(os.path.join(theme_dir_1x, f"battery_alert_{p}.png"))
            im2.save(os.path.join(theme_dir_2x, f"battery_alert_{p}@2x.png"))
            count += 2

        im1 = create_standard_battery(scale=1, pct=0, state="missing", theme=theme_key)
        im2 = create_standard_battery(scale=2, pct=0, state="missing", theme=theme_key)
        im1.save(os.path.join(theme_dir_1x, "battery_missing.png"))
        im2.save(os.path.join(theme_dir_2x, "battery_missing@2x.png"))
        count += 2

    # 2. Compact Battery-10
    for theme_key, _ in themes:
        theme_dir_1x = os.path.join(OUTPUT_DIR, "compact_battery10", theme_key, "1x")
        theme_dir_2x = os.path.join(OUTPUT_DIR, "compact_battery10", theme_key, "2x")
        os.makedirs(theme_dir_1x, exist_ok=True)
        os.makedirs(theme_dir_2x, exist_ok=True)

        for p in percentages:
            im1 = create_compact_battery(scale=1, pct=p, state="normal", theme=theme_key)
            im2 = create_compact_battery(scale=2, pct=p, state="normal", theme=theme_key)
            im1.save(os.path.join(theme_dir_1x, f"battery10_{p}.png"))
            im2.save(os.path.join(theme_dir_2x, f"battery10_{p}@2x.png"))
            count += 2

        for p in percentages:
            im1 = create_compact_battery(scale=1, pct=p, state="charging", theme=theme_key)
            im2 = create_compact_battery(scale=2, pct=p, state="charging", theme=theme_key)
            im1.save(os.path.join(theme_dir_1x, f"battery10_charging_{p}.png"))
            im2.save(os.path.join(theme_dir_2x, f"battery10_charging_{p}@2x.png"))
            count += 2

    # 3. UPS Battery
    for theme_key, _ in themes:
        theme_dir_1x = os.path.join(OUTPUT_DIR, "ups", theme_key, "1x")
        theme_dir_2x = os.path.join(OUTPUT_DIR, "ups", theme_key, "2x")
        os.makedirs(theme_dir_1x, exist_ok=True)
        os.makedirs(theme_dir_2x, exist_ok=True)

        for p in percentages:
            im1 = create_ups_battery(scale=1, pct=p, state="normal", theme=theme_key)
            im2 = create_ups_battery(scale=2, pct=p, state="normal", theme=theme_key)
            im1.save(os.path.join(theme_dir_1x, f"ups_{p}.png"))
            im2.save(os.path.join(theme_dir_2x, f"ups_{p}@2x.png"))
            count += 2

        im1 = create_ups_battery(scale=1, state="charging", theme=theme_key)
        im2 = create_ups_battery(scale=2, state="charging", theme=theme_key)
        im1.save(os.path.join(theme_dir_1x, "ups_charging.png"))
        im2.save(os.path.join(theme_dir_2x, "ups_charging@2x.png"))

        im1 = create_ups_battery(scale=1, state="charged", theme=theme_key)
        im2 = create_ups_battery(scale=2, state="charged", theme=theme_key)
        im1.save(os.path.join(theme_dir_1x, "ups_charged.png"))
        im2.save(os.path.join(theme_dir_2x, "ups_charged@2x.png"))
        count += 4

    print(f"Generated {count} individual battery PNG assets successfully!")

def create_card(icon_img, label_text, bg_color, text_color, zoom=3):
    iw, ih = icon_img.size
    scaled_w, scaled_h = iw * zoom, ih * zoom
    zoomed_img = icon_img.resize((scaled_w, scaled_h), Image.NEAREST)
    
    card_w = max(scaled_w + 24, 94)
    card_h = scaled_h + 38
    card = Image.new("RGBA", (card_w, card_h), bg_color)
    draw = ImageDraw.Draw(card)
    
    ix = (card_w - scaled_w) // 2
    iy = 10
    card.paste(zoomed_img, (ix, iy), zoomed_img)
    
    font = get_font(12)
    bbox = draw.textbbox((0, 0), label_text, font=font)
    tw = bbox[2] - bbox[0]
    tx = (card_w - tw) // 2
    ty = iy + scaled_h + 6
    draw.text((tx, ty), label_text, fill=text_color, font=font)
    
    border_col = (text_color[0], text_color[1], text_color[2], 35)
    draw.rounded_rectangle([0, 0, card_w - 1, card_h - 1], radius=6, outline=border_col, width=1)
    return card

def build_contact_sheets():
    sheet_dir = os.path.join(OUTPUT_DIR, "sheets")
    os.makedirs(sheet_dir, exist_ok=True)
    
    percentages = [0, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100]
    
    for theme_key, theme_title, bg_card, bg_sheet, txt_col in [
        ("dark", "Standard Battery - Dark Mode (Rounded Fill, Red <=20%, Orange 21-50%, Green >50%)", (38, 38, 42, 255), (24, 24, 26, 255), (240, 240, 245, 255)),
        ("light", "Standard Battery - Light Mode (Rounded Fill, Red <=20%, Orange 21-50%, Green >50%)", (245, 245, 247, 255), (255, 255, 255, 255), (20, 20, 20, 255)),
        ("colored_dark", "Standard Battery - System Colors (Dark)", (38, 38, 42, 255), (24, 24, 26, 255), (240, 240, 245, 255)),
        ("colored", "Standard Battery - System Colors (Light)", (245, 245, 247, 255), (255, 255, 255, 255), (20, 20, 20, 255)),
    ]:
        rows = [
            ("Normal / Discharging (Inner Fill Radius following Border)", [
                (create_standard_battery(scale=2, pct=p, state="normal", theme=theme_key), f"{p}%") for p in percentages
            ]),
            ("Charging (Bolt) - with Radius-Conforming Fill", [
                (create_standard_battery(scale=2, pct=p, state="charging", theme=theme_key), f"{p}%") for p in percentages
            ]),
            ("Plugged In (AC Adapter) - with Radius-Conforming Fill", [
                (create_standard_battery(scale=2, pct=p, state="plugged", theme=theme_key), f"{p}%") for p in percentages
            ]),
            ("Alert & Missing", [
                (create_standard_battery(scale=2, pct=p, state="alert", theme=theme_key), f"Alert {p}%") for p in [0, 20, 40, 50, 100]
            ] + [
                (create_standard_battery(scale=2, pct=0, state="missing", theme=theme_key), "Missing 'X'"),
            ]),
        ]
        
        card_w, card_h = 100, 100
        pad_x, pad_y = 12, 14
        margin_x, margin_y = 30, 70
        
        max_cols = 11
        sheet_w = margin_x * 2 + max_cols * card_w + (max_cols - 1) * pad_x
        sheet_h = margin_y + len(rows) * (card_h + pad_y + 35) + 30
        
        sheet = Image.new("RGBA", (sheet_w, sheet_h), bg_sheet)
        draw = ImageDraw.Draw(sheet)
        
        font_title = get_font(24)
        draw.text((margin_x, 24), theme_title, fill=txt_col, font=font_title)
        
        cur_y = margin_y
        font_section = get_font(15)
        
        for section_name, items in rows:
            draw.text((margin_x, cur_y), section_name, fill=txt_col, font=font_section)
            cur_y += 28
            
            for col_idx, (icon, lbl) in enumerate(items):
                card = create_card(icon, lbl, bg_card, txt_col, zoom=2)
                cx = margin_x + col_idx * (card_w + pad_x)
                sheet.paste(card, (cx, cur_y), card)
                
            cur_y += card_h + pad_y
            
        sheet.save(os.path.join(sheet_dir, f"standard_battery_sheet_{theme_key}.png"))
        print(f"Saved sheet: standard_battery_sheet_{theme_key}.png")

    # Master Overview Sheet
    print("Building master overview contact sheet...")
    master_w = 1580
    master_h = 1820
    master = Image.new("RGBA", (master_w, master_h), (22, 23, 27, 255))
    mdraw = ImageDraw.Draw(master)
    
    font_main = get_font(28)
    font_sub = get_font(15)
    font_sec = get_font(18)
    
    mdraw.text((40, 30), "macOS Extracted Battery Icons - Master Matrix (Radius-Conforming Fill)", fill=(255, 255, 255), font=font_main)
    mdraw.text((40, 70), "Inner fill radius follows border contour: Red (<=20%), Orange (21-50%), Green (51-100%)", fill=(160, 165, 175), font=font_sub)
    
    sections = [
        ("1. Standard Battery: Normal States (Dark Mode @2x)", "dark", "normal"),
        ("2. Standard Battery: Charging Bolt Overlay (Dark Mode @2x)", "dark", "charging"),
        ("3. Standard Battery: Plugged In AC Overlay (Dark Mode @2x)", "dark", "plugged"),
        ("4. Compact Battery-10: Normal & Charging (Dark Mode @2x)", "dark", "compact"),
        ("5. UPS Vertical Battery System (@2x)", "dark", "ups"),
    ]
    
    my = 110
    card_bg = (34, 36, 42, 255)
    text_c = (235, 240, 245, 255)
    
    for title, thm, cat in sections:
        mdraw.text((40, my), title, fill=(255, 214, 10), font=font_sec)
        my += 28
        
        if cat in ("normal", "charging", "plugged"):
            cols = [0, 10, 20, 30, 40, 50, 60, 70, 80, 90, 100]
            items = []
            for p in cols:
                items.append((create_standard_battery(scale=2, pct=p, state=cat, theme=thm), f"{cat.capitalize()} {p}%"))
            if cat == "normal":
                items.append((create_standard_battery(scale=2, pct=100, state="alert", theme=thm), "Alert"))
                items.append((create_standard_battery(scale=2, pct=0, state="missing", theme=thm), "Missing"))
            
            for idx, (ic, lb) in enumerate(items):
                cd = create_card(ic, lb, card_bg, text_c, zoom=2)
                cx = 40 + idx * (cd.width + 6)
                if cx + cd.width <= master_w:
                    master.paste(cd, (cx, my), cd)
            my += 118
            
        elif cat == "compact":
            items = []
            for p in [0, 10, 20, 30, 40, 50, 80, 100]:
                items.append((create_compact_battery(scale=2, pct=p, state="normal", theme=thm), f"Level {p}%"))
            for p in [0, 10, 20, 30, 40, 50, 80, 100]:
                items.append((create_compact_battery(scale=2, pct=p, state="charging", theme=thm), f"Bolt {p}%"))
            for idx, (ic, lb) in enumerate(items):
                cd = create_card(ic, lb, card_bg, text_c, zoom=2)
                cx = 40 + idx * (cd.width + 6)
                if cx + cd.width <= master_w:
                    master.paste(cd, (cx, my), cd)
            my += 118
            
        elif cat == "ups":
            items = []
            for p in [0, 10, 20, 30, 40, 50, 80, 100]:
                items.append((create_ups_battery(scale=2, pct=p, state="normal", theme=thm), f"UPS {p}%"))
            items.append((create_ups_battery(scale=2, state="charging", theme=thm), "UPS Charging"))
            items.append((create_ups_battery(scale=2, state="charged", theme=thm), "UPS Charged"))
            for idx, (ic, lb) in enumerate(items):
                cd = create_card(ic, lb, card_bg, text_c, zoom=2)
                cx = 40 + idx * (cd.width + 6)
                if cx + cd.width <= master_w:
                    master.paste(cd, (cx, my), cd)
            my += 118

    master.save(os.path.join(sheet_dir, "master_contact_sheet.png"))
    print("Saved master contact sheet: master_contact_sheet.png")

if __name__ == "__main__":
    generate_all_assets()
    build_contact_sheets()
