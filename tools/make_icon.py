"""Draw the LocalShift app icon: three glass shapes orbiting on a frosted tile.

python3 tools/make_icon.py            -> Assets/AppIcon.icns and work/icon/AppIcon-1024.png
The shapes and colours match LSIcon.appMark in Sources/RadialOverlay.swift; change both together.
"""
from pathlib import Path
import math
import sys

from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
SCALE = 4                      # draw at 4096 px, then downsample for clean edges
SIDE = 1024 * SCALE

BLUE = (35, 64, 216)           # triangle
YELLOW = (255, 177, 43)        # circle
WINE = (121, 8, 18)            # hexagon

# Apple's macOS icon grid: an 824 px tile centred on the 1024 px canvas.
TILE = (100, 100, 924, 924)
TILE_RADIUS = 186
CENTER = (512, 522)
ORBIT = 150
ANGLES = {'triangle': -90, 'circle': 30, 'hexagon': 150}


def px(value):
    return int(round(value * SCALE))


def mask_from(draw_fn):
    mask = Image.new('L', (SIDE, SIDE), 0)
    draw_fn(ImageDraw.Draw(mask))
    return mask


def rounded_polygon(points, radius, steps=24):
    """Polygon with every corner replaced by a circular arc of the given radius."""
    result = []
    count = len(points)
    for index in range(count):
        prev_point, point, next_point = points[index - 1], points[index], points[(index + 1) % count]
        v1 = (prev_point[0] - point[0], prev_point[1] - point[1])
        v2 = (next_point[0] - point[0], next_point[1] - point[1])
        l1, l2 = math.hypot(*v1), math.hypot(*v2)
        u1, u2 = (v1[0] / l1, v1[1] / l1), (v2[0] / l2, v2[1] / l2)
        angle = math.acos(max(-1, min(1, u1[0] * u2[0] + u1[1] * u2[1])))
        offset = radius / math.tan(angle / 2)
        start = (point[0] + u1[0] * offset, point[1] + u1[1] * offset)
        end = (point[0] + u2[0] * offset, point[1] + u2[1] * offset)
        bisector = (u1[0] + u2[0], u1[1] + u2[1])
        length = math.hypot(*bisector)
        distance = radius / math.sin(angle / 2)
        centre = (point[0] + bisector[0] / length * distance, point[1] + bisector[1] / length * distance)
        a0 = math.atan2(start[1] - centre[1], start[0] - centre[0])
        a1 = math.atan2(end[1] - centre[1], end[0] - centre[0])
        sweep = (a1 - a0 + math.pi) % (2 * math.pi) - math.pi
        for step in range(steps + 1):
            a = a0 + sweep * step / steps
            result.append((centre[0] + radius * math.cos(a), centre[1] + radius * math.sin(a)))
    return result


def regular(center, circumradius, sides, rotation):
    return [(center[0] + circumradius * math.cos(math.radians(rotation + 360 * i / sides)),
             center[1] + circumradius * math.sin(math.radians(rotation + 360 * i / sides))) for i in range(sides)]


def shape_points(kind):
    angle = math.radians(ANGLES[kind])
    center = (CENTER[0] + ORBIT * math.cos(angle), CENTER[1] + ORBIT * math.sin(angle))
    if kind == 'triangle':
        # Optical centre of a triangle sits low; nudge it down so the trio looks balanced.
        center = (center[0], center[1] + 14)
        return rounded_polygon(regular(center, 128, 3, -90), 30)
    if kind == 'hexagon':
        return rounded_polygon(regular(center, 104, 6, 0), 18)
    return None


def shape_mask(kind):
    if kind == 'circle':
        angle = math.radians(ANGLES[kind])
        cx, cy = CENTER[0] + ORBIT * math.cos(angle), CENTER[1] + ORBIT * math.sin(angle)
        radius = 96
        return mask_from(lambda d: d.ellipse((px(cx - radius), px(cy - radius), px(cx + radius), px(cy + radius)), fill=255))
    points = [(px(x), px(y)) for x, y in shape_points(kind)]
    return mask_from(lambda d: d.polygon(points, fill=255))


def vertical_gradient(top, bottom):
    column = Image.new('RGBA', (1, 256))
    for y in range(256):
        t = y / 255
        column.putpixel((0, y), tuple(int(round(top[i] + (bottom[i] - top[i]) * t)) for i in range(4)))
    return column.resize((SIDE, SIDE), Image.BILINEAR)


def mix(color, other, amount):
    return tuple(int(round(color[i] + (other[i] - color[i]) * amount)) for i in range(3))


def bbox_of(mask):
    return mask.getbbox()


def paint_glass_shape(canvas, kind, color):
    mask = shape_mask(kind)
    left, top, right, bottom = bbox_of(mask)

    # Coloured contact shadow, as if light passes through tinted glass.
    shadow = mask.filter(ImageFilter.GaussianBlur(px(20)))
    shadow = ImageChops.offset(shadow, 0, px(22)).point(lambda v: int(v * 0.30))
    canvas.alpha_composite(Image.composite(Image.new('RGBA', (SIDE, SIDE), color + (255,)), Image.new('RGBA', (SIDE, SIDE), color + (0,)), shadow))

    # Body: lighter at the top, full colour at the bottom.
    body = Image.new('RGBA', (SIDE, SIDE), (0, 0, 0, 0))
    gradient = Image.new('RGBA', (1, 256))
    for y in range(256):
        t = y / 255
        gradient.putpixel((0, y), mix(mix(color, (255, 255, 255), 0.30), color, t) + (255,))
    gradient = gradient.resize((right - left, bottom - top), Image.BILINEAR)
    body.paste(gradient, (left, top))
    # Slightly translucent, so the wheel track reads through the glass.
    canvas.alpha_composite(Image.composite(body, Image.new('RGBA', (SIDE, SIDE), (0, 0, 0, 0)), mask.point(lambda v: int(v * 0.96))))

    # Inner rim: a thin light edge just inside the outline.
    inner = mask.filter(ImageFilter.MinFilter(px(4) | 1))
    rim = ImageChops.subtract(mask, inner).filter(ImageFilter.GaussianBlur(px(1)))
    rim_top = Image.new('L', (SIDE, SIDE), 0)
    ImageDraw.Draw(rim_top).rectangle((0, 0, SIDE, top + (bottom - top) * 0.55), fill=255)
    rim_top = rim_top.filter(ImageFilter.GaussianBlur(px(40)))
    rim = ImageChops.multiply(rim, rim_top).point(lambda v: int(v * 0.85))
    canvas.alpha_composite(Image.composite(Image.new('RGBA', (SIDE, SIDE), (255, 255, 255, 255)), Image.new('RGBA', (SIDE, SIDE), (255, 255, 255, 0)), rim))

    # Specular sheen across the upper part.
    sheen = Image.new('L', (SIDE, SIDE), 0)
    width, height = right - left, bottom - top
    ImageDraw.Draw(sheen).ellipse((left - width * 0.10, top - height * 0.50, right + width * 0.10, top + height * 0.38), fill=255)
    sheen = ImageChops.multiply(sheen.filter(ImageFilter.GaussianBlur(px(34))), mask).point(lambda v: int(v * 0.30))
    canvas.alpha_composite(Image.composite(Image.new('RGBA', (SIDE, SIDE), (255, 255, 255, 255)), Image.new('RGBA', (SIDE, SIDE), (255, 255, 255, 0)), sheen))


def draw_icon():
    canvas = Image.new('RGBA', (SIDE, SIDE), (0, 0, 0, 0))
    tile_box = tuple(px(v) for v in TILE)
    tile = mask_from(lambda d: d.rounded_rectangle(tile_box, radius=px(TILE_RADIUS), fill=255))

    # Drop shadow under the tile, like every macOS app icon.
    shadow = ImageChops.offset(tile.filter(ImageFilter.GaussianBlur(px(18))), 0, px(10)).point(lambda v: int(v * 0.30))
    canvas.alpha_composite(Image.composite(Image.new('RGBA', (SIDE, SIDE), (0, 0, 0, 255)), Image.new('RGBA', (SIDE, SIDE), (0, 0, 0, 0)), shadow))

    # Frosted tile: near-white with a cool bottom.
    face = vertical_gradient((255, 255, 255, 255), (232, 235, 242, 255))
    canvas.alpha_composite(Image.composite(face, Image.new('RGBA', (SIDE, SIDE), (0, 0, 0, 0)), tile))

    # The wheel track the shapes ride on.
    r = ORBIT
    track = mask_from(lambda d: d.ellipse((px(CENTER[0] - r), px(CENTER[1] - r), px(CENTER[0] + r), px(CENTER[1] + r)), outline=255, width=px(14)))
    track = track.filter(ImageFilter.GaussianBlur(px(1.2)))
    canvas.alpha_composite(Image.composite(Image.new('RGBA', (SIDE, SIDE), (20, 30, 60, 255)), Image.new('RGBA', (SIDE, SIDE), (20, 30, 60, 0)), track.point(lambda v: int(v * 0.09))))

    for kind, color in (('hexagon', WINE), ('circle', YELLOW), ('triangle', BLUE)):
        paint_glass_shape(canvas, kind, color)

    # Glass edge on the tile: bright top rim, faint dark bottom rim.
    inner = tile.filter(ImageFilter.MinFilter(px(3) | 1))
    edge = ImageChops.subtract(tile, inner)
    top_half = Image.new('L', (SIDE, SIDE), 0)
    ImageDraw.Draw(top_half).rectangle((0, 0, SIDE, px(512)), fill=255)
    top_half = top_half.filter(ImageFilter.GaussianBlur(px(160)))
    canvas.alpha_composite(Image.composite(Image.new('RGBA', (SIDE, SIDE), (255, 255, 255, 255)), Image.new('RGBA', (SIDE, SIDE), (255, 255, 255, 0)), ImageChops.multiply(edge, top_half)))
    canvas.alpha_composite(Image.composite(Image.new('RGBA', (SIDE, SIDE), (0, 0, 0, 255)), Image.new('RGBA', (SIDE, SIDE), (0, 0, 0, 0)), ImageChops.multiply(edge, ImageChops.invert(top_half)).point(lambda v: int(v * 0.10))))

    return canvas.resize((1024, 1024), Image.LANCZOS)


def main():
    icon = draw_icon()
    preview = ROOT / 'work/icon'
    preview.mkdir(parents=True, exist_ok=True)
    icon.save(preview / 'AppIcon-1024.png')
    for size in (16, 32, 64, 128):
        icon.resize((size, size), Image.LANCZOS).save(preview / f'AppIcon-{size}.png')
    if '--preview' in sys.argv:
        return
    icon.save(ROOT / 'Assets/AppIcon.icns', sizes=[(16, 16), (32, 32), (64, 64), (128, 128), (256, 256), (512, 512), (1024, 1024)])


if __name__ == '__main__':
    main()
