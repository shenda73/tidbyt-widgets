"""
Stock alert for Tidbyt.
A full-screen alert for a watched ticker that has made a big move. It opens
with a shockwave in the move's color, then shows the ticker, the change since
the previous close in large type, and the day's price as a glowing line
crossing the amber level that set the alert off (the gray dotted line is the
previous close).

The Lambda decides when to send it (lambda/alerts.py) and passes the data in;
it is pushed to the front of the Tidbyt once and is not kept in the rotation.

Config:
  data     JSON: {"alerts": [{"label", "pct", "up", "level", "prev",
           "closes": [...]}]}. Without it, shows a sample.
  seconds  seconds on screen per alert (default 7)
"""

load("encoding/json.star", "json")
load("math.star", "math")
load("render.star", "render")

W, H = 64, 32
BIG = "6x13"  # 6 px per character
SMALL = "tom-thumb"  # 4 px per character
TOP = 15  # chart rows 15..31
ROWS = 17
GLOW_ROWS = 8
LABEL_ROWS = 6  # height kept free for the level label
DELAY_MS = 100
WAVE = 10  # frames of shockwave
FADE = 6  # frames for the text to fade in
DRAW = 16  # frames for the line to draw in

UP, DOWN = "#2fe07a", "#ff4d5e"
LEVEL = "#ffb020"
PREV = "#555555"

SAMPLE = {
    "alerts": [{
        "label": "TSLA",
        "pct": 6.2,
        "up": True,
        "level": 6.0,
        "prev": 400.0,
        "closes": [
            401, 402, 400.5, 403, 404, 403.5, 405, 404, 406, 407, 406.5, 408,
            409, 408, 410, 412, 411, 413, 415, 414, 416, 419, 418, 421, 423, 424.8,
        ],
    }],
}

HEX = "0123456789abcdef"

def clamp(v, lo, hi):
    return max(lo, min(hi, v))

def hex2(v):
    return HEX[v // 16] + HEX[v % 16]

def lerp_color(a, b, t):
    """Blend hex colors a -> b by t in [0, 1]."""
    t = clamp(t, 0.0, 1.0)
    out = "#"
    for i in (1, 3, 5):
        ca, cb = int(a[i:i + 2], 16), int(b[i:i + 2], 16)
        out += hex2(clamp(int(ca + (cb - ca) * t + 0.5), 0, 255))
    return out

def ease_out(t):
    t = clamp(t, 0.0, 1.0)
    return 1.0 - math.pow(1.0 - t, 3)

def px(x, y, color, w = 1, h = 1):
    return render.Padding(
        pad = (x, y, 0, 0),
        child = render.Box(width = w, height = h, color = color),
    )

def pct_text(pct):
    a = abs(pct)
    sign = "+" if pct >= 0 else "-"
    if a >= 9.95:
        return "%s%d%%" % (sign, int(math.round(a)))
    n = int(math.round(a * 10))
    return "%s%d.%d%%" % (sign, n // 10, n % 10)

def level_text(level):
    sign = "+" if level >= 0 else "-"
    a = abs(level)
    if a == int(a):
        return "%s%d%%" % (sign, int(a))
    n = int(math.round(a * 10))
    return "%s%d.%d%%" % (sign, n // 10, n % 10)

def shockwave(i, color):
    """Two rectangles racing from the center to the edges, fading as they go."""
    out = []
    for k in range(2):
        p = ease_out((i + 1 - 3 * k) / (WAVE - 3))
        if p <= 0 or p >= 1:
            continue
        hw, hh = int(p * W / 2), int(p * H / 2)
        c = lerp_color(color, "#000000", p * 0.6)
        x0, y0 = W // 2 - hw, H // 2 - hh
        w, h = max(1, 2 * hw), max(1, 2 * hh)
        out += [
            px(x0, y0, c, w = w),
            px(x0, min(H - 1, y0 + h - 1), c, w = w),
            px(x0, y0, c, h = h),
            px(min(W - 1, x0 + w - 1), y0, c, h = h),
        ]
    return out

def arrow(x, y, up, color):
    """A 7x4 triangle pointing up or down."""
    out = []
    for r in range(4):
        w = 1 + 2 * r if up else 7 - 2 * r
        out.append(px(x + (7 - w) // 2, y + r, color, w = w))
    return out

def header(a, color, alpha, bob):
    label = a["label"][:5]
    text = pct_text(a["pct"])
    text_x = W - 6 * len(text)
    label_end = 1 + 6 * len(label)
    out = [
        render.Padding(pad = (1, 0, 0, 0), child = render.Text(label, font = BIG, color = lerp_color("#000000", "#ffffff", alpha))),
        render.Padding(pad = (text_x, 0, 0, 0), child = render.Text(text, font = BIG, color = lerp_color("#000000", color, alpha))),
    ]
    if text_x - label_end >= 9:
        ax = label_end + (text_x - label_end - 7) // 2
        out += arrow(ax, 5 + bob, a["up"], lerp_color("#000000", color, alpha))
    return out

def chart_rows(a):
    """One chart row per column for the day's line, plus the rows of the
    previous close and of the level that was crossed."""
    closes = a["closes"]
    if len(closes) < 2:
        closes = [a["prev"], closes[0] if closes else a["prev"]]
    level_price = a["prev"] * (1 + a["level"] / 100)
    hi = max(closes + [a["prev"], level_price])
    lo = min(closes + [a["prev"], level_price])
    if hi == lo:
        hi += 0.01

    # Leave room for the level's label beyond the level line: above it for
    # a rise, below it for a fall.
    top = LABEL_ROWS if a["up"] else 0
    span = ROWS - 1 - LABEL_ROWS

    def row(p):
        return top + clamp(int((hi - p) / (hi - lo) * span + 0.5), 0, span)

    cols = []
    for x in range(W):
        at = x * (len(closes) - 1) / (W - 1)
        i = min(int(at), len(closes) - 2)
        cols.append(row(closes[i] + (closes[i + 1] - closes[i]) * (at - i)))
    return cols, row(a["prev"]), row(level_price)

def chart(a, color, cols, prev_row, level_row, shown):
    """The chart up to column `shown`; returns widgets and the tip position."""
    out = []

    # Glow under the line.
    for depth in range(1, GLOW_ROWS + 1):
        fill = lerp_color("#000000", color, 0.5 * math.pow(1.0 - (depth - 1) / GLOW_ROWS, 1.5))
        run = None
        for x in range(shown + 1):
            y = cols[x] + depth if x < shown else None
            if run != None and y != run[1]:
                if run[1] < ROWS:
                    out.append(px(run[0], TOP + run[1], fill, w = x - run[0]))
                run = None
            if y != None and run == None:
                run = (x, y)

    # Previous close and the crossed level, dotted, across the whole width.
    if prev_row != level_row:
        for x in range(1, W, 3):
            out.append(px(x, TOP + prev_row, PREV))
    for x in range(0, W, 2):
        out.append(px(x, TOP + level_row, LEVEL))

    # The level's label sits on the left, on the side of the level line
    # that the price line is not on.
    text = level_text(a["level"])
    width = 4 * len(text) + 1
    line_above = len([x for x in range(width) if cols[x] < level_row]) > 0
    line_below = len([x for x in range(width) if cols[x] > level_row]) > 0
    above = not line_above if a["up"] or line_below else False
    ty = clamp(level_row - LABEL_ROWS if above else level_row + 2, 0, ROWS - LABEL_ROWS)
    out.append(px(0, TOP + ty - 1, "#000000", w = width, h = LABEL_ROWS + 1))
    out.append(render.Padding(pad = (0, TOP + ty, 0, 0), child = render.Text(text, font = SMALL, color = LEVEL)))

    last = None
    for x in range(shown):
        y = cols[x]
        y0, y1 = (y, y) if last == None else (min(y, last), max(y, last))
        if last != None and y != last:
            if y > last:
                y0 += 1
            else:
                y1 -= 1
        out.append(px(x, TOP + y0, color, h = y1 - y0 + 1))
        last = y
    tip = (shown - 1, TOP + last) if last != None else None
    return out, tip

def alert_frames(a, n):
    color = UP if a["up"] else DOWN
    cols, prev_row, level_row = chart_rows(a)
    full, dot = chart(a, color, cols, prev_row, level_row, W)
    full = render.Stack(children = full)

    frames = []
    for i in range(n):
        kids = []
        if i < WAVE:
            kids += shockwave(i, color)
        if i >= WAVE - FADE:
            alpha = clamp((i - (WAVE - FADE) + 1) / FADE, 0.0, 1.0)
            bob = 1 if (i // 5) % 2 == 0 else 0
            kids += header(a, color, alpha, bob if a["up"] else -bob)
        if i >= WAVE:
            k = i - WAVE
            if k < DRAW:
                shown = max(1, int(ease_out((k + 1) / DRAW) * W + 0.5))
                part, tip = chart(a, color, cols, prev_row, level_row, shown)
                kids += part
                kids.append(px(tip[0], tip[1], "#ffffff"))
            else:
                pulse = 0.5 - 0.5 * math.cos(2 * math.pi * (k - DRAW) / 14)
                halo = lerp_color("#000000", "#ffffff", 0.15 + 0.4 * pulse)
                x, y = dot
                kids.append(full)
                for dx, dy in [(-1, 0), (0, -1), (0, 1)]:
                    if TOP <= y + dy and y + dy < H:
                        kids.append(px(x + dx, y + dy, halo))
                kids.append(px(x, y, "#ffffff"))
        frames.append(render.Stack(children = kids))
    return frames

def main(config):
    data = json.decode(config.get("data")) if config.get("data") else SAMPLE
    n = int(config.get("seconds", "7")) * 1000 // DELAY_MS

    frames = []
    for a in data.get("alerts") or []:
        frames += alert_frames(a, n)
    if not frames:
        return []
    return render.Root(delay = DELAY_MS, child = render.Animation(children = frames))
