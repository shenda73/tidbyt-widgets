"""
Sun Arc for Tidbyt.
A pixel sun travels along an arc from sunrise to sunset; at night a moon
travels it from sunset to the next sunrise. The sky color follows the sun.

Animated: by day the sun's glow pulses and clouds drift by; at night the
stars twinkle and a shooting star crosses once per loop.

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
HORIZON = 24  # y of the horizon line; the sky is rows 0..23
CX = 32  # arc center x
RX = 27  # arc horizontal radius
RY = 20  # arc vertical radius
FONT = "tom-thumb"

DEFAULT_LAT = "40.7128"
DEFAULT_LNG = "-74.0060"
DEFAULT_TZ = "America/New_York"

# Animation: FRAMES * DELAY_MS is one loop (~15 s, about one rotation slot).
# Everything that moves repeats exactly within FRAMES so the loop is seamless.
FRAMES = 152
DELAY_MS = 100
PULSE = 38  # frames per sun-glow pulse (FRAMES / 4)
WRAP = 76  # clouds wrap after moving this far (64 + room to enter and leave)

# Fixed star positions for the night sky (x, y).
STARS = [
    (4, 3), (11, 9), (17, 2), (24, 6), (29, 1), (37, 4), (43, 10),
    (48, 2), (55, 7), (60, 3), (8, 15), (57, 14), (20, 12), (40, 16),
]

# Cloud shapes as rows of (x offset, width).
CLOUD_BIG = [(3, 4), (1, 9), (0, 12)]
CLOUD_SMALL = [(2, 3), (0, 7)]

# Clouds: shape, y, start offset, pixels moved per frame (WRAP / speed must
# divide FRAMES, so speeds are 0.5 or 1.0).
CLOUDS = [
    (CLOUD_BIG, 4, 10, 0.5),
    (CLOUD_SMALL, 12, 50, 1.0),
]

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

def wave(i, period, phase = 0.0):
    """0..1 sine wave over `period` frames."""
    return 0.5 + 0.5 * math.sin(2 * math.pi * (i / period + phase))

def arc_point(f):
    """Point on the arc for progress f (0 = left horizon, 1 = right horizon)."""
    theta = math.pi * (1.0 - f)
    x = CX + RX * math.cos(theta)
    y = HORIZON - RY * math.sin(theta)
    return int(math.round(x)), int(math.round(y))

def arc_dots(f, done_color, todo_color):
    """Dotted arc: the part already traveled is brighter."""
    dots = []
    seen = {}
    n = 120
    for i in range(n + 1):
        p = i / n
        x, y = arc_point(p)
        if (x, y) in seen or y >= HORIZON:
            continue
        seen[(x, y)] = True
        if len(seen) % 2 == 0:
            continue
        dots.append(pixel(x, y, done_color if p <= f else todo_color))
    return dots

def sky(top, bottom):
    rows = []
    for y in range(HORIZON):
        rows.append(pixel(0, y, lerp_color(top, bottom, y / (HORIZON - 1)), w = W))
    return rows

def disc(x, y, diameter, color):
    r = diameter // 2
    return render.Padding(
        pad = (max(0, x - r), max(0, y - r), 0, 0),
        child = render.Circle(diameter = diameter, color = color),
    )

def fmt_duration(seconds):
    mins = int(seconds // 60)
    h, m = mins // 60, mins % 60
    if h == 0:
        return "%dm" % m
    return "%dh%s%dm" % (h, "0" if m < 10 else "", m)

def day_frame(i, x, y, t):
    """Moving parts by day: pulsing sun glow and drifting clouds."""
    glow = lerp_color("#c0502a", "#9ccff5", t)
    sun = lerp_color("#ff6a1a", "#fff2a8", t)
    p = wave(i, PULSE)
    layers = [
        disc(x, y, 13, lerp_color(glow, sun, 0.12 * p)),
        disc(x, y, 11, lerp_color(glow, sun, 0.25 + 0.2 * p)),
        disc(x, y, 7, sun),
    ]

    # Clouds pass in front of the sun: pinkish in golden hour, white at midday.
    cloud = lerp_color("#f4b4a0", "#ffffff", t)
    shade = lerp_color("#c98a8a", "#d8e8f8", t)
    for shape, cy, start, speed in CLOUDS:
        cx = int(start + i * speed) % WRAP - 12
        for row, (dx, w) in enumerate(shape):
            color = shade if row == len(shape) - 1 else cloud
            layers += hspan(cx + dx, cy + row, w, color)
    return layers

def night_frame(i, x, y, t):
    """Moving parts at night: twinkling stars and one shooting star per loop."""
    layers = []
    dim = lerp_color("#3a3050", "#3c4470", t)
    bright = lerp_color("#7a6a90", "#e8ecff", t)
    for n, (sx, sy) in enumerate(STARS):
        # Stars twinkle at two speeds with their own phase.
        period = PULSE if n % 2 else 2 * PULSE
        layers.append(pixel(sx, sy, lerp_color(dim, bright, wave(i, period, n * 0.37))))

    layers.append(disc(x, y, 7, "#e8ecff"))
    layers.append(disc(x + 2, y - 1, 5, lerp_color("#3a2850", "#060a1e", t)))  # crescent shadow

    # Shooting star: a short trail sliding down-left for 10 frames.
    start = 96
    if start <= i and i < start + 10:
        k = i - start
        head_x, head_y = 58 - 3 * k, 1 + k
        for j, color in enumerate(["#ffffff", "#a0b0e0", "#505c90"]):
            px, py = head_x + 2 * j, head_y - j
            if 0 <= px and px < W and 0 <= py and py < HORIZON:
                layers.append(pixel(px, py, color, w = 2))
    return layers

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

    # Static background: sky and arc.
    if is_day:
        t = clamp(height / 0.5, 0.0, 1.0)  # how far the sun is out of golden hour
        background = sky(
            lerp_color("#2a2f6e", "#1d5fc4", t),
            lerp_color("#f2793a", "#7cc0f2", t),
        )
        background += arc_dots(f, "#ffe08a", lerp_color("#c9a0a0", "#c8e4ff", t))
        horizon_color = lerp_color("#ff9a4a", "#5fae4f", t)
        left_color, right_color = "#ffd36b", "#ff8a3d"
        make_frame = day_frame
    else:
        t = clamp(height / 0.25, 0.0, 1.0)  # how far we are from twilight
        background = sky(
            lerp_color("#141238", "#02030c", t),
            lerp_color("#5a2e5e", "#0c1636", t),
        )
        background += arc_dots(f, "#8c96c8", "#2c3460")
        horizon_color = lerp_color("#a0507a", "#23305a", t)
        left_color, right_color = "#ff8a3d", "#ffd36b"
        make_frame = night_frame

    # Moving layer, between the sky and the ground.
    if config.get("frame"):
        moving = render.Stack(children = make_frame(int(config.get("frame")), x, y, t))
    else:
        moving = render.Animation(children = [
            render.Stack(children = make_frame(i, x, y, t))
            for i in range(FRAMES)
        ])

    # Ground drawn last so it hides the bottom of the sun/moon at the horizon.
    ground = [
        pixel(0, HORIZON, horizon_color, w = W),
        pixel(0, HORIZON + 1, "#000000", w = W, h = 32 - HORIZON - 1),
    ]

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
        child = render.Stack(children = background + [moving] + ground + [label]),
    )
