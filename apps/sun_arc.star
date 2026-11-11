"""
Sun Arc for Tidbyt.
An abstract take on the day: the sky is a stack of flat color bands, the sun
is a plain disc on a thin arc from sunrise to sunset, and rings ripple out
from it. At night the disc becomes a hollow ring (the moon) traveling from
sunset to the next sunrise. The palette follows the time of day.

Config (all optional):
  lat, lng   location (default: New York City)
  tz         IANA timezone (default: America/New_York)
  time       RFC 3339 timestamp to render instead of now (for previews)
  frame      render only this animation frame (for previews)
"""

load("math.star", "math")
load("render.star", "render")
load("sunrise.star", "sunrise")
load("time.star", "time")

W = 64
HORIZON = 24  # the sky is rows 0..23; the label sits below
CX = 32  # arc center x
RX = 27  # arc horizontal radius
RY = 20  # arc vertical radius
FONT = "tom-thumb"

DEFAULT_LAT = "40.7128"
DEFAULT_LNG = "-74.0060"
DEFAULT_TZ = "America/New_York"

# Sky bands from top to bottom, as row counts (they add up to HORIZON).
BANDS = [7, 6, 5, 4, 2]

# Ripples: RING_COUNT rings spaced RING_GAP apart move out from the disc and
# fade. Each ring takes FRAMES frames to reach the next ring's place, so the
# loop is seamless.
FRAMES = 48
DELAY_MS = 100
RING_GAP = 7
RING_COUNT = 4
DISC_R = 3.4  # a 7 px disc

def clamp(v, lo, hi):
    return max(lo, min(hi, v))

HEX = "0123456789abcdef"

def hex2(v):
    return HEX[v // 16] + HEX[v % 16]

def parse_hex(c):
    return [int(c[i:i + 2], 16) for i in (1, 3, 5)]

def lerp_color(a, b, t):
    """Blend hex colors a -> b by t in [0, 1]."""
    t = clamp(t, 0.0, 1.0)
    ca, cb = parse_hex(a), parse_hex(b)
    out = "#"
    for i in range(3):
        v = int(ca[i] + (cb[i] - ca[i]) * t + 0.5)
        out += hex2(clamp(v, 0, 255))
    return out

def pixel(x, y, color, w = 1, h = 1):
    return render.Padding(
        pad = (x, y, 0, 0),
        child = render.Box(width = w, height = h, color = color),
    )

def hspan(x, y, w, color):
    """Horizontal run of pixels, clipped to the screen."""
    x0, x1 = max(0, x), min(W, x + w)
    if x1 <= x0:
        return []
    return [pixel(x0, y, color, w = x1 - x0)]

def band_rows(top, bottom):
    """Color of each sky row: flat bands stepping from top to bottom."""
    rows = []
    for k, h in enumerate(BANDS):
        rows += [lerp_color(top, bottom, k / (len(BANDS) - 1))] * h
    return rows

def arc_point(f):
    """Point on the arc for progress f (0 = left horizon, 1 = right horizon)."""
    theta = math.pi * (1.0 - f)
    x = CX + RX * math.cos(theta)
    y = HORIZON - RY * math.sin(theta)
    return int(math.round(x)), int(math.round(y))

def arc_line(f, rows, done_color):
    """Thin arc: the part already traveled is bright, the rest a faint trace."""
    out = []
    seen = {}
    n = 240
    for i in range(n + 1):
        p = i / n
        x, y = arc_point(p)
        if (x, y) in seen or y >= HORIZON:
            continue
        seen[(x, y)] = True
        if p <= f:
            out.append(pixel(x, y, lerp_color(rows[y], done_color, 0.85)))
        else:
            out.append(pixel(x, y, lerp_color(rows[y], "#ffffff", 0.18)))
    return out

def disc(cx, cy, r, color):
    """Filled circle, clipped to the sky."""
    out = []
    for y in range(max(0, int(cy - r)), min(HORIZON, int(cy + r) + 1)):
        dy = y - cy
        if dy * dy > r * r:
            continue
        a = int(math.sqrt(r * r - dy * dy))
        out += hspan(cx - a, y, 2 * a + 1, color)
    return out

def ring(cx, cy, r, rows, color, alpha):
    """1 px circle outline blended over the sky bands, clipped to the sky."""
    out = []
    ro, ri = r + 0.5, r - 0.5
    for y in range(max(0, int(cy - ro)), min(HORIZON, int(cy + ro) + 1)):
        dy = y - cy
        if dy * dy > ro * ro:
            continue
        a_out = int(math.sqrt(ro * ro - dy * dy))
        c = lerp_color(rows[y], color, alpha)
        if dy * dy < ri * ri:
            a_in = int(math.sqrt(ri * ri - dy * dy))
            out += hspan(cx - a_out, y, a_out - a_in, c)
            out += hspan(cx + a_in + 1, y, a_out - a_in, c)
        else:
            out += hspan(cx - a_out, y, 2 * a_out + 1, c)
    return out

def ripples(i, cx, cy, rows, color, strength):
    """Rings moving out from the disc, fading as they go."""
    out = []
    for k in range(RING_COUNT):
        u = (k + i / FRAMES) / RING_COUNT  # 0 at the disc, 1 fully faded
        r = DISC_R + 1.5 + u * RING_COUNT * RING_GAP
        alpha = strength * (1.0 - u) * min(1.0, 0.3 + u * 6)
        out += ring(cx, cy, r, rows, color, alpha)
    return out

def fmt_duration(seconds):
    mins = int(seconds // 60)
    h, m = mins // 60, mins % 60
    if h == 0:
        return "%dm" % m
    return "%dh%s%dm" % (h, "0" if m < 10 else "", m)

def main(config):
    lat = float(config.get("lat", DEFAULT_LAT))
    lng = float(config.get("lng", DEFAULT_LNG))
    tz = config.get("tz", DEFAULT_TZ)

    if config.get("time"):
        now = time.parse_time(config.get("time")).in_location(tz)
    else:
        now = time.now().in_location(tz)

    day = time.parse_duration("24h")
    rise = sunrise.sunrise(lat, lng, now).in_location(tz)
    sset = sunrise.sunset(lat, lng, now).in_location(tz)

    is_day = rise <= now and now < sset
    if is_day:
        start, end = rise, sset
    elif now < rise:
        start, end = sunrise.sunset(lat, lng, now - day).in_location(tz), rise
    else:
        start, end = sset, sunrise.sunrise(lat, lng, now + day).in_location(tz)

    total = (end - start).seconds
    f = clamp((now - start).seconds / total, 0.0, 1.0)
    height = math.sin(math.pi * f)  # 0 at the horizon, 1 at the top of the arc
    x, y = arc_point(f)

    if is_day:
        t = clamp(height / 0.5, 0.0, 1.0)  # how far the sun is out of golden hour
        rows = band_rows(
            lerp_color("#2a2f6e", "#1d5fc4", t),
            lerp_color("#f2793a", "#7cc0f2", t),
        )
        body_color = lerp_color("#ff6a1a", "#fff2a8", t)
        ripple_color, strength = body_color, 0.5
        body = disc(x, y, DISC_R, body_color)
        left_color, right_color = "#ffd36b", "#ff8a3d"
    else:
        t = clamp(height / 0.25, 0.0, 1.0)  # how far we are from twilight
        rows = band_rows(
            lerp_color("#141238", "#02030c", t),
            lerp_color("#5a2e5e", "#0c1636", t),
        )
        body_color = "#e8ecff"
        ripple_color, strength = "#8c96e8", 0.45

        # The moon is hollow: an outline with the sky showing through.
        body = disc(x, y, DISC_R, body_color) + disc(x, y, DISC_R - 1.3, rows[clamp(y, 0, HORIZON - 1)])
        left_color, right_color = "#ff8a3d", "#ffd36b"

    sky = [pixel(0, r, rows[r], w = W) for r in range(HORIZON)]
    arc = arc_line(f, rows, body_color)

    # Ripples move; everything else is still.
    if config.get("frame"):
        moving = render.Stack(children = ripples(int(config.get("frame")), x, y, rows, ripple_color, strength))
    else:
        moving = render.Animation(children = [
            render.Stack(children = ripples(i, x, y, rows, ripple_color, strength))
            for i in range(FRAMES)
        ])

    remaining = fmt_duration((end - now).seconds)
    label = render.Padding(
        pad = (1, HORIZON + 2, 1, 0),
        child = render.Row(
            expanded = True,
            main_align = "space_between",
            children = [
                render.Text(start.format("3:04"), font = FONT, color = left_color),
                render.Text(remaining, font = FONT, color = "#9a9a9a"),
                render.Text(end.format("3:04"), font = FONT, color = right_color),
            ],
        ),
    )

    return render.Root(
        delay = DELAY_MS,
        child = render.Stack(children = sky + [moving] + arc + body + [label]),
    )
