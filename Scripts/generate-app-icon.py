#!/usr/bin/env python3
"""Generate the CodexBar Lite macOS app icon."""

from __future__ import annotations

import math
import shutil
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter


SIZE = 1024
SCALE = 4
CANVAS = SIZE * SCALE


def s(value: float) -> int:
    return int(round(value * SCALE))


def mix(a: tuple[int, int, int], b: tuple[int, int, int], t: float) -> tuple[int, int, int]:
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def composite_blur(base: Image.Image, shape: Image.Image, radius: float) -> None:
    base.alpha_composite(shape.filter(ImageFilter.GaussianBlur(s(radius))))


def draw_background(size: int) -> Image.Image:
    top = (28, 32, 42)
    bottom = (4, 5, 9)
    image = Image.new("RGBA", (size, size), (0, 0, 0, 255))
    draw = ImageDraw.Draw(image)

    for y in range(size):
        t = y / (size - 1)
        draw.line([(0, y), (size, y)], fill=(*mix(top, bottom, t), 255))

    glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    glow_draw = ImageDraw.Draw(glow)
    glow_draw.ellipse(
        [s(-210), s(-170), s(740), s(680)],
        fill=(100, 126, 170, 58),
    )
    glow_draw.ellipse(
        [s(500), s(110), s(1280), s(920)],
        fill=(255, 45, 85, 30),
    )
    glow_draw.ellipse(
        [s(-120), s(480), s(620), s(1220)],
        fill=(48, 215, 75, 24),
    )
    composite_blur(image, glow, 80)

    return image


def gradient(size: int, start: tuple[int, int, int], end: tuple[int, int, int]) -> Image.Image:
    image = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    for x in range(size):
        t = x / (size - 1)
        draw.line([(x, 0), (x, size)], fill=(*mix(start, end, t), 255))
    return image


def draw_ring_shadow(base: Image.Image, bbox: list[int], width: int, opacity: int, blur: float) -> None:
    shadow = Image.new("RGBA", base.size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(shadow)
    offset = s(8)
    moved = [bbox[0] + offset, bbox[1] + offset, bbox[2] + offset, bbox[3] + offset]
    draw.ellipse(moved, outline=(0, 0, 0, opacity), width=width)
    composite_blur(base, shadow, blur)


def arc_points(
    center: tuple[int, int],
    radius: int,
    start: float,
    end: float,
    steps: int,
) -> list[tuple[int, int]]:
    points = []
    for index in range(steps + 1):
        angle = start + (end - start) * index / steps
        radians = math.radians(angle)
        points.append((
            int(round(center[0] + math.cos(radians) * radius)),
            int(round(center[1] + math.sin(radians) * radius)),
        ))
    return points


def draw_arc(
    base: Image.Image,
    bbox: list[int],
    width: int,
    fraction: float,
    start_color: tuple[int, int, int],
    end_color: tuple[int, int, int],
) -> None:
    center = ((bbox[0] + bbox[2]) // 2, (bbox[1] + bbox[3]) // 2)
    radius = (bbox[2] - bbox[0]) // 2
    start = -90
    end = start + 360 * fraction

    mask = Image.new("L", base.size, 0)
    mask_draw = ImageDraw.Draw(mask)
    steps = max(32, int(abs(end - start) * 1.6))
    points = arc_points(center, radius, start, end, steps)
    mask_draw.line(points, fill=255, width=width, joint="curve")
    cap_radius = width // 2
    for point in (points[0], points[-1]):
        mask_draw.ellipse(
            [
                point[0] - cap_radius,
                point[1] - cap_radius,
                point[0] + cap_radius,
                point[1] + cap_radius,
            ],
            fill=255,
        )

    color = gradient(base.size[0], start_color, end_color)
    color.putalpha(mask)
    base.alpha_composite(color)

    shine_mask = Image.new("L", base.size, 0)
    shine_draw = ImageDraw.Draw(shine_mask)
    inset = width // 4
    inner_bbox = [bbox[0] + inset, bbox[1] + inset, bbox[2] - inset, bbox[3] - inset]
    shine_draw.arc(inner_bbox, start=start + 2, end=end - 2, fill=120, width=max(s(7), width // 7))
    shine_alpha = shine_mask.point(lambda value: min(62, int(value * 0.42)))
    shine = Image.new("RGBA", base.size, (255, 255, 255, 0))
    shine.putalpha(shine_alpha)
    base.alpha_composite(shine)


def draw_rings(image: Image.Image) -> None:
    draw = ImageDraw.Draw(image)
    center = s(512)

    outer_radius = s(326)
    outer_width = s(106)
    inner_radius = s(202)
    inner_width = s(92)

    outer_bbox = [
        center - outer_radius,
        center - outer_radius,
        center + outer_radius,
        center + outer_radius,
    ]
    inner_bbox = [
        center - inner_radius,
        center - inner_radius,
        center + inner_radius,
        center + inner_radius,
    ]

    draw_ring_shadow(image, outer_bbox, outer_width, 180, 18)
    draw_ring_shadow(image, inner_bbox, inner_width, 160, 14)

    draw.ellipse(outer_bbox, outline=(58, 63, 76, 255), width=outer_width)
    draw.ellipse(inner_bbox, outline=(43, 49, 58, 255), width=inner_width)

    draw_arc(image, outer_bbox, outer_width, 0.82, (255, 42, 86), (255, 92, 116))
    draw_arc(image, inner_bbox, inner_width, 0.67, (48, 215, 75), (110, 252, 130))

    well = Image.new("RGBA", image.size, (0, 0, 0, 0))
    well_draw = ImageDraw.Draw(well)
    well_draw.ellipse([s(335), s(335), s(689), s(689)], fill=(0, 0, 0, 120))
    composite_blur(image, well, 10)

    draw = ImageDraw.Draw(image)
    draw.ellipse([s(350), s(350), s(674), s(674)], fill=(16, 19, 26, 246))
    draw.ellipse([s(372), s(372), s(652), s(652)], outline=(255, 255, 255, 24), width=s(3))
    draw.ellipse([s(426), s(426), s(598), s(598)], fill=(24, 28, 37, 255))
    draw.ellipse([s(440), s(440), s(584), s(584)], outline=(0, 0, 0, 95), width=s(6))


def generate_png(path: Path) -> None:
    image = draw_background(CANVAS)
    draw_rings(image)
    image = image.resize((SIZE, SIZE), Image.Resampling.LANCZOS)
    opaque = Image.new("RGBA", (SIZE, SIZE), (5, 6, 10, 255))
    opaque.alpha_composite(image)
    opaque.putalpha(255)
    image = opaque
    image.save(path)


def generate_icns(root: Path, png: Path) -> None:
    iconset = root / ".build" / "icon" / "AppIcon.iconset"
    if iconset.exists():
        shutil.rmtree(iconset)
    iconset.mkdir(parents=True)

    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            pixels = size * scale
            suffix = "@2x" if scale == 2 else ""
            out = iconset / f"icon_{size}x{size}{suffix}.png"
            subprocess.run(
                ["sips", "-z", str(pixels), str(pixels), str(png), "--out", str(out)],
                check=True,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )

    subprocess.run(
        ["iconutil", "-c", "icns", str(iconset), "-o", str(root / "Resources" / "AppIcon.icns")],
        check=True,
    )


def main() -> None:
    root = Path(__file__).resolve().parents[1]
    png = root / "Resources" / "AppIcon.png"
    generate_png(png)
    generate_icns(root, png)
    print(png)
    print(root / "Resources" / "AppIcon.icns")


if __name__ == "__main__":
    main()
