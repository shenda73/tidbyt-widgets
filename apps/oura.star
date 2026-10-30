"""
Oura 7-day trends for Tidbyt.
One row per score (sleep, readiness, activity): seven daily bars with today's
lit up, then today's score and the change since yesterday. The bars grow in
when the widget comes on, then today's bar glows.

The Lambda fetches the data from the Oura API and passes it in as JSON, so
the app itself needs no credentials.

Config:
  data   JSON: {"series": {"sleep"|"readiness"|"activity": [7 scores, oldest
         first, null when missing]}}. Without it, shows sample data.
"""

load("encoding/json.star", "json")
load("render.star", "render")

FONT = "tom-thumb"
ROW_Y = [0, 11, 22]  # each row is 10 px tall, with a 1-px line between rows
BAR_X = 14  # first bar; bars are 3 px wide on a 4 px pitch
BAR_MAX = 9
LO, HI = 50, 100  # score range mapped onto the bar height
GROW_FRAMES = 12
HOLD_FRAMES = 138  # (GROW + HOLD) * DELAY_MS is about one rotation slot
DELAY_MS = 100
UP, DOWN, FLAT = "#2ee86a", "#ff4d4d", "#888888"

# key, label, bright color, dim color (past days)
ROWS = [
    ("sleep", "SLP", "#6c9cff", "#2a3f6e"),
    ("readiness", "RDY", "#3ddc97", "#1a5c40"),
    ("activity", "ACT", "#ffa53d", "#6b4518"),
]

SAMPLE = {"series": {
    "sleep": [78, 82, 75, 88, 80, 84, 87],
    "readiness": [70, 74, 79, 83, 85, 83, 81],
    "activity": [60, 72, 55, 80, 66, 62, 67],
}}

def pixel(x, y, color, w = 1, h = 1):
    return render.Padding(pad = (x, y, 0, 0), child = render.Box(width = w, height = h, color = color))

def text(x, y, s, color):
    return render.Padding(pad = (x, y, 0, 0), child = render.Text(s, font = FONT, color = color))

def bar_height(v):
    if v == None:
        return 0
    t = (min(max(v, LO), HI) - LO) / (HI - LO)
    return max(1, int(t * BAR_MAX + 0.5))

def arrow(x, y, up, color):
    rows = [(2, 1), (1, 3), (0, 5)]  # (x offset, width) per row, tip first
    return [pixel(x + dx, y + (i if up else 2 - i), color, w = w) for i, (dx, w) in enumerate(rows)]

def row(y0, spec, series, grow, glow):
    key, label, color, dim = spec
    kids = [text(0, y0 + 2, label, color)]
    base = y0 + BAR_MAX  # bottom row of the bars

    n = len(series)
    for i, v in enumerate(series):
        x = BAR_X + 4 * (7 - n + i)
        today = i == n - 1
        if v == None:
            kids.append(pixel(x, base, "#222222", w = 3))  # missing day
            continue
        h = max(1, int(bar_height(v) * grow + 0.5))
        kids.append(pixel(x, base - h + 1, color if today else dim, w = 3, h = h))
        if today and glow:
            kids.append(pixel(x, base - h + 1, "#ffffff", w = 3))

    vals = [v for v in series if v != None]
    cur = series[-1] if series else None
    if cur == None:
        kids.append(text(44, y0 + 2, "--", "#666666"))
        return kids
    kids.append(text(44, y0 + 2, str(int(cur)), "#ffffff"))

    prev = vals[-2] if len(vals) > 1 else None
    if prev != None:
        d = int(cur) - int(prev)
        if d == 0:
            kids.append(text(57, y0 + 2, "=", FLAT))
        elif abs(d) < 10:
            c = UP if d > 0 else DOWN
            kids.extend(arrow(53, y0 + 3, d > 0, c))
            kids.append(text(59, y0 + 2, str(abs(d)), c))
        else:
            # No room for the arrow next to two digits: show the sign instead.
            kids.append(text(53, y0 + 2, ("+" if d > 0 else "-") + str(abs(d)), UP if d > 0 else DOWN))
    return kids

def frame(data, grow, glow):
    series = data.get("series", {})
    kids = [pixel(0, ROW_Y[1] - 1, "#1c1c1c", w = 64), pixel(0, ROW_Y[2] - 1, "#1c1c1c", w = 64)]
    for r, spec in enumerate(ROWS):
        kids.extend(row(ROW_Y[r], spec, series.get(spec[0]) or [None] * 7, grow, glow))
    return render.Stack(children = kids)

def ease(t):
    return 1 - (1 - t) * (1 - t) * (1 - t)

def main(config):
    raw = config.get("data")
    data = json.decode(raw) if raw else SAMPLE
    if data.get("error"):
        return render.Root(child = render.Column(
            expanded = True,
            main_align = "center",
            cross_align = "center",
            children = [
                render.Text("OURA", color = "#6c9cff"),
                render.Text(data["error"][:16], font = FONT, color = "#888888"),
            ],
        ))

    frames = [frame(data, ease((i + 1) / GROW_FRAMES), False) for i in range(GROW_FRAMES)]

    # Hold: today's bars glow on and off. Reuse two frames to keep rendering fast.
    on, off = frame(data, 1.0, True), frame(data, 1.0, False)
    for i in range(HOLD_FRAMES):
        frames.append(on if (i // 8) % 2 == 0 else off)

    return render.Root(delay = DELAY_MS, show_full_animation = True, child = render.Animation(children = frames))
