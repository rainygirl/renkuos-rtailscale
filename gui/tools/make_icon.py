#!/usr/bin/env python3
"""Draw the R Tailscale icon in the BeOS style and write it out.

A mesh of three devices as a solid object: a dark slab lying on the isometric
plane the other R icons use, three pucks standing on it joined by links, one
of them lit. Light comes from the top left, so every piece shows its face, a
darker flank facing down-left and a darker one still facing down-right, and
each piece sits on a dark outline.

Everything is a straight-edged polygon in flat colour, so the same list of
shapes is both the HVIF and the picture:

  RTailscale.rdef     the vector_icon resource (rewritten in place)
  RTailscale.hvif     the same bytes as a file
  ../icon.png         256 px render, for the README (needs Pillow)

Regenerate with:  python3 gui/tools/make_icon.py
"""
import io
import math
import os
import re

OUTLINE = (24, 28, 36)
SLAB = (58, 70, 92)
LINK = (132, 148, 172)
NODE = (232, 237, 244)
LIT = (82, 204, 124)

SLAB_HEIGHT = 7.0       # pixels each piece stands off the plane below it
NODE_HEIGHT = 4.5
NODE_RADIUS = 0.62      # in grid units; the plane is 5 x 5
LINK_WIDTH = 0.44

# Grid positions of the three devices; the one at the back is lit.
NODES = [((0.95, 0.95), LIT), ((4.05, 2.35), NODE), ((2.35, 4.05), NODE)]


def shade(colour, factor):
    return tuple(min(255, int(round(c * factor))) for c in colour)


def project(gx, gy, lift=0.0):
    """+x runs down to the right, +y down to the left; lift is in pixels."""
    u, v = gx / 5.0, gy / 5.0
    return (32.0 + 30.0 * u - 30.0 * v, 16.0 + 15.0 * u + 15.0 * v - lift)


def rounded_rect(x0, y0, x1, y1, radius, steps=5):
    corners = [(x1 - radius, y0 + radius, -90.0), (x1 - radius, y1 - radius, 0.0),
               (x0 + radius, y1 - radius, 90.0), (x0 + radius, y0 + radius, 180.0)]
    points = []
    for cx, cy, start in corners:
        for s in range(steps + 1):
            a = math.radians(start + 90.0 * s / steps)
            points.append((cx + radius * math.cos(a), cy + radius * math.sin(a)))
    return points


def disc(cx, cy, radius, sides=24):
    return [(cx + radius * math.cos(2 * math.pi * i / sides),
             cy + radius * math.sin(2 * math.pi * i / sides)) for i in range(sides)]


def hull(points):
    points = sorted(set((round(x, 4), round(y, 4)) for x, y in points))

    def half(seq):
        out = []
        for p in seq:
            while len(out) >= 2 and ((out[-1][0] - out[-2][0]) * (p[1] - out[-2][1])
                                     - (out[-1][1] - out[-2][1]) * (p[0] - out[-2][0])) <= 0:
                out.pop()
            out.append(p)
        return out[:-1]

    return half(points) + half(reversed(points))


def grow(points, amount):
    """Push a convex outline outwards by `amount` pixels."""
    n = len(points)
    area = sum(a[0] * b[1] - b[0] * a[1] for a, b in zip(points, points[1:] + points[:1]))
    sign = 1.0 if area > 0 else -1.0
    out = []
    for i in range(n):
        (ax, ay), (bx, by), (cx, cy) = points[i - 1], points[i], points[(i + 1) % n]
        normals = []
        for (px, py), (qx, qy) in (((ax, ay), (bx, by)), ((bx, by), (cx, cy))):
            dx, dy = qx - px, qy - py
            length = math.hypot(dx, dy) or 1.0
            normals.append((sign * dy / length, -sign * dx / length))
        nx, ny = normals[0][0] + normals[1][0], normals[0][1] + normals[1][1]
        length = math.hypot(nx, ny) or 1.0
        out.append((bx + amount * nx / length, by + amount * ny / length))
    return out


def solid(shapes, outline_grid, colour, base, height, edge):
    """A prism: the outline in grid units, standing `height` px on `base` px."""
    top = [project(x, y, base + height) for x, y in outline_grid]
    foot = [project(x, y, base) for x, y in outline_grid]
    silhouette = hull(top + foot)
    shapes.append((OUTLINE, grow(silhouette, edge)))
    # The flank is what the face leaves of the silhouette. Split it at the
    # lowest point into the side facing down-left and the one down-right.
    lowest = max(top, key=lambda p: p[1])
    left = [p for p in top if p[0] <= lowest[0] + 1e-6]
    right = [p for p in top if p[0] >= lowest[0] - 1e-6]
    shapes.append((shade(colour, 0.70), hull(left + [(x, y + height) for x, y in left])))
    shapes.append((shade(colour, 0.50), hull(right + [(x, y + height) for x, y in right])))
    shapes.append((colour, top))


def build_shapes():
    shapes = []
    slab = rounded_rect(0.0, 0.0, 5.0, 5.0, 0.9)
    solid(shapes, slab, SLAB, 0.0, SLAB_HEIGHT, 1.3)
    # A lighter band round the face, the way a bevel catches the light.
    shapes.append((shade(SLAB, 1.28),
                   [project(x, y, SLAB_HEIGHT) for x, y in slab]))
    shapes.append((SLAB, [project(x, y, SLAB_HEIGHT)
                          for x, y in rounded_rect(0.22, 0.22, 4.78, 4.78, 0.72)]))

    # Links lie flat on the slab, under the pucks.
    centres = [c for c, _ in NODES]
    for i in range(3):
        (ax, ay), (bx, by) = centres[i], centres[(i + 1) % 3]
        dx, dy = bx - ax, by - ay
        length = math.hypot(dx, dy)
        nx, ny = -dy / length * LINK_WIDTH / 2, dx / length * LINK_WIDTH / 2
        for colour, k in ((OUTLINE, 1.9), (LINK, 1.0)):
            quad = [(ax + nx * k, ay + ny * k), (bx + nx * k, by + ny * k),
                    (bx - nx * k, by - ny * k), (ax - nx * k, ay - ny * k)]
            shapes.append((colour, [project(x, y, SLAB_HEIGHT) for x, y in quad]))

    for (cx, cy), colour in sorted(NODES, key=lambda n: n[0][0] + n[0][1]):
        solid(shapes, disc(cx, cy, NODE_RADIUS), colour, SLAB_HEIGHT, NODE_HEIGHT, 1.1)
        # Highlight on the face, towards the light.
        shapes.append(((255, 255, 255) if colour == NODE else shade(colour, 1.16),
                       [project(x, y, SLAB_HEIGHT + NODE_HEIGHT)
                        for x, y in disc(cx - 0.14, cy - 0.14, NODE_RADIUS * 0.52, 16)]))

    # Fill the 64 px box with a 2 px margin, as the other R icons do.
    xs = [x for _, pts in shapes for x, _ in pts]
    ys = [y for _, pts in shapes for _, y in pts]
    scale = min(60.0 / (max(xs) - min(xs)), 60.0 / (max(ys) - min(ys)))
    dx = 32.0 - scale * (max(xs) + min(xs)) / 2.0
    dy = 32.0 - scale * (max(ys) + min(ys)) / 2.0
    return [(c, [(x * scale + dx, y * scale + dy) for x, y in pts]) for c, pts in shapes]


def coord(value):
    # Two-byte HVIF coordinate: ((b0 & 0x7f) << 8 | b1) / 102 - 128.
    encoded = int(round((value + 128.0) * 102))
    return bytes([0x80 | (encoded >> 8), encoded & 0xFF])


def hvif(shapes):
    styles = []
    for colour, _ in shapes:
        if colour not in styles:
            styles.append(colour)
    data = bytearray(b"ncif")
    data.append(len(styles))
    for colour in styles:
        data.append(1)
        data += bytes(colour) + b"\xff"
    data.append(len(shapes))
    for _, points in shapes:
        if len(points) > 255:
            raise SystemExit("too many points: %d" % len(points))
        data += bytes([0x02 | 0x08, len(points)])   # closed, no curves
        for px, py in points:
            data += coord(px) + coord(py)
    data.append(len(shapes))
    for index, (colour, _) in enumerate(shapes):
        data += bytes([0x0A, styles.index(colour), 1, index, 0])
    return bytes(data)


def png(shapes, path, size=256, k=4):
    from PIL import Image, ImageDraw
    image = Image.new("RGBA", (size * k, size * k), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    f = size * k / 64.0
    for colour, points in shapes:
        draw.polygon([(x * f, y * f) for x, y in points], fill=colour + (255,))
    image.resize((size, size), Image.LANCZOS).save(path, optimize=True)


def main():
    here = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    shapes = build_shapes()
    data = hvif(shapes)
    path = os.path.join(here, "RTailscale.rdef")
    text = io.open(path, encoding="utf-8").read()
    value = "".join("%02X" % b for b in data)
    block = "resource vector_icon {\n" + "".join(
        '\t$"%s"\n' % value[i:i + 64] for i in range(0, len(value), 64)) + "};\n"
    text = re.sub(r"resource vector_icon \{.*?\};\n", lambda _: block, text,
                  flags=re.S)
    io.open(path, "w", encoding="utf-8").write(text)
    # The same bytes as a file, for packaging without Haiku's rc/xres.
    with open(os.path.join(here, "RTailscale.hvif"), "wb") as f:
        f.write(data)
    print("RTailscale.rdef, RTailscale.hvif: wrote %d-byte HVIF, %d shapes"
          % (len(data), len(shapes)))
    try:
        png(shapes, os.path.join(os.path.dirname(here), "icon.png"))
        print("icon.png: 256 px")
    except ImportError:
        print("icon.png not written: Pillow is not installed")


if __name__ == "__main__":
    main()
