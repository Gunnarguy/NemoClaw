#!/usr/bin/env python3
"""Generate NemoClaw macOS app icons (.icns) from scratch using Pillow."""
# SPDX-FileCopyrightText: Copyright (c) 2026 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

import math
import os
import shutil
import subprocess
import sys
import tempfile

from PIL import Image, ImageDraw, ImageFont

SIZES = [16, 32, 64, 128, 256, 512, 1024]

# NVIDIA green palette
NVIDIA_GREEN = (118, 185, 0)
DARK_BG = (30, 30, 30)
WHITE = (255, 255, 255)
ACCENT_TEAL = (0, 170, 180)
RECOVERY_AMBER = (255, 160, 0)


def draw_rounded_rect(draw, bbox, radius, fill):
    """Draw a rounded rectangle."""
    x0, y0, x1, y1 = bbox
    draw.rectangle([x0 + radius, y0, x1 - radius, y1], fill=fill)
    draw.rectangle([x0, y0 + radius, x1, y1 - radius], fill=fill)
    draw.pieslice([x0, y0, x0 + 2 * radius, y0 + 2 * radius], 180, 270, fill=fill)
    draw.pieslice([x1 - 2 * radius, y0, x1, y0 + 2 * radius], 270, 360, fill=fill)
    draw.pieslice([x0, y1 - 2 * radius, x0 + 2 * radius, y1], 90, 180, fill=fill)
    draw.pieslice([x1 - 2 * radius, y1 - 2 * radius, x1, y1], 0, 90, fill=fill)


def draw_claw(draw, cx, cy, size, color, rotation=0):
    """Draw a stylized 3-prong claw symbol."""
    prong_length = size * 0.38
    prong_width = size * 0.08
    spread_angle = 35

    angles = [-spread_angle + rotation, 0 + rotation, spread_angle + rotation]

    for angle_deg in angles:
        angle_rad = math.radians(angle_deg - 90)
        tip_x = cx + prong_length * math.cos(angle_rad)
        tip_y = cy + prong_length * math.sin(angle_rad)

        perp_rad = angle_rad + math.pi / 2
        dx = prong_width * math.cos(perp_rad)
        dy = prong_width * math.sin(perp_rad)

        # Tapered prong
        base_width = prong_width * 1.8
        bdx = base_width * math.cos(perp_rad)
        bdy = base_width * math.sin(perp_rad)

        polygon = [
            (cx - bdx, cy - bdy),
            (cx + bdx, cy + bdy),
            (tip_x + dx * 0.3, tip_y + dy * 0.3),
            (tip_x - dx * 0.3, tip_y - dy * 0.3),
        ]
        draw.polygon(polygon, fill=color)

        # Curved tip
        tip_r = prong_width * 0.4
        draw.ellipse(
            [tip_x - tip_r, tip_y - tip_r, tip_x + tip_r, tip_y + tip_r],
            fill=color,
        )

    # Base circle
    base_r = size * 0.1
    draw.ellipse([cx - base_r, cy - base_r, cx + base_r, cy + base_r], fill=color)


def generate_icon(size, variant="main"):
    """Generate a single icon at the given size."""
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    margin = int(size * 0.05)
    corner_radius = int(size * 0.18)

    # Background
    bg_color = DARK_BG
    draw_rounded_rect(
        draw,
        (margin, margin, size - margin, size - margin),
        corner_radius,
        bg_color,
    )

    # Accent stripe at bottom
    accent = NVIDIA_GREEN if variant == "main" else RECOVERY_AMBER
    stripe_h = int(size * 0.06)
    stripe_y = size - margin - int(size * 0.14)
    draw_rounded_rect(
        draw,
        (
            margin + int(size * 0.1),
            stripe_y,
            size - margin - int(size * 0.1),
            stripe_y + stripe_h,
        ),
        stripe_h // 2,
        accent,
    )

    # Claw symbol
    claw_cy = int(size * 0.35)
    claw_size = size * 0.55
    claw_color = NVIDIA_GREEN if variant == "main" else RECOVERY_AMBER
    draw_claw(draw, size // 2, claw_cy, claw_size, claw_color)

    # Text label
    label = "NC" if variant == "main" else "RC"
    try:
        font_size = int(size * 0.16)
        font = ImageFont.truetype("/System/Library/Fonts/SFCompact.ttf", font_size)
    except (OSError, IOError):
        try:
            font = ImageFont.truetype(
                "/System/Library/Fonts/Helvetica.ttc", int(size * 0.16)
            )
        except (OSError, IOError):
            font = ImageFont.load_default()

    text_bbox = draw.textbbox((0, 0), label, font=font)
    text_w = text_bbox[2] - text_bbox[0]
    text_x = (size - text_w) // 2
    text_y = int(size * 0.68)
    draw.text((text_x, text_y), label, fill=WHITE, font=font)

    return img


def build_iconset(variant, output_path):
    """Build a .icns file from generated images."""
    tmpdir = tempfile.mkdtemp()
    iconset_dir = os.path.join(tmpdir, f"icon.iconset")
    os.makedirs(iconset_dir)

    try:
        for sz in SIZES:
            img = generate_icon(sz, variant)
            img.save(os.path.join(iconset_dir, f"icon_{sz}x{sz}.png"))
            # @2x variant (half the stated size)
            if sz >= 32:
                half = sz // 2
                img_2x = generate_icon(sz, variant)
                img_2x.save(os.path.join(iconset_dir, f"icon_{half}x{half}@2x.png"))

        subprocess.run(
            ["iconutil", "-c", "icns", iconset_dir, "-o", output_path],
            check=True,
            capture_output=True,
        )
        print(f"  Created: {output_path}")
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    repo_dir = os.path.dirname(script_dir)

    # Output directly to Desktop app bundles
    main_app = os.path.expanduser("~/Desktop/NemoClaw.app/Contents/Resources")
    recovery_app = os.path.expanduser(
        "~/Desktop/NemoClaw Recovery.app/Contents/Resources"
    )

    os.makedirs(main_app, exist_ok=True)
    os.makedirs(recovery_app, exist_ok=True)

    print("Generating NemoClaw icons...")
    build_iconset("main", os.path.join(main_app, "NemoClaw.icns"))
    build_iconset("recovery", os.path.join(recovery_app, "NemoClawRecovery.icns"))

    # Also save to repo for version control
    assets_dir = os.path.join(repo_dir, "Desktop", "icons")
    os.makedirs(assets_dir, exist_ok=True)
    build_iconset("main", os.path.join(assets_dir, "NemoClaw.icns"))
    build_iconset("recovery", os.path.join(assets_dir, "NemoClawRecovery.icns"))

    # Touch app bundles to refresh Finder
    for app in [
        os.path.expanduser("~/Desktop/NemoClaw.app"),
        os.path.expanduser("~/Desktop/NemoClaw Recovery.app"),
    ]:
        if os.path.isdir(app):
            subprocess.run(["touch", app], check=False)

    print("Done. Restart Finder or log out/in if icons don't update immediately.")


if __name__ == "__main__":
    main()
