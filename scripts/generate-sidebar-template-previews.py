#!/usr/bin/env python3
"""Generate small light and dark gallery preview cards for the curated templates."""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "Packages/macOS/CmuxSettingsUI/Sources/CmuxSettingsUI/Resources/CustomSidebarTemplatePreviews"
TEMPLATES = {
    "workspaces": ("Workspaces", "left"),
    "agents-board": ("Agents Board", "left"),
    "panel-sessions": ("Panel Sessions", "right"),
    "panel-subagents": ("Panel Subagents", "right"),
    "btop-agents": ("btop Agents", "left"),
    "panel-todo": ("Panel Todo", "right"),
}
font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 18)
small = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 12)
for slug, (title, placement) in TEMPLATES.items():
    for theme, palette in {
        "dark": ((24, 27, 34), (34, 39, 49), (235, 240, 248), (151, 163, 180), (47, 54, 67), (215, 221, 231)),
        "light": ((246, 247, 249), (255, 255, 255), (28, 32, 40), (91, 99, 112), (235, 238, 243), (48, 55, 66)),
    }.items():
        background, card, title_color, secondary, row_color, row_text = palette
        image = Image.new("RGB", (640, 360), background)
        draw = ImageDraw.Draw(image)
        draw.rounded_rectangle((24, 24, 616, 336), radius=18, fill=card, outline=(76, 158, 235), width=2)
        draw.text((48, 44), title, fill=title_color, font=font)
        draw.text((48, 76), f"{placement} sidebar preview · {theme}", fill=secondary, font=small)
        for row in range(5):
            y = 124 + row * 38
            draw.rounded_rectangle((48, y, 592, y + 24), radius=6, fill=row_color)
            draw.ellipse((60, y + 7, 68, y + 15), fill=(76, 158, 235) if row == 0 else (106, 117, 134))
            draw.text((82, y + 4), ["cmux", "Build", "Review", "Agents", "Todo"][row], fill=row_text, font=small)
        image.save(OUT / f"{slug}-{theme}.png", optimize=True)
