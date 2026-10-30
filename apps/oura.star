"""
Oura 7-day trends for Tidbyt.
One row per score (sleep, readiness, activity): a line chart of the last
seven days ending on a bright dot for today, then today's score and the change
since yesterday. The lines draw in from the left when the widget comes on,
then today's dot glows.

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
CHART_X, CHART_W = 14, 28  # chart spans x 14..41
CHART_H = 9  # rows y0+1 .. y0+9 of each row
MIN_SPAN = 10  # least score range shown, so small wiggles stay small
DRAW_FRAMES = 14
HOLD_FRAMES = 136  # (DRAW + HOLD) * DELAY_MS is about one rotation slot
DELAY_MS = 100
UP, DOWN, FLAT = "#2ee86a", "#ff4d4d", "#888888"

# key, label, line color, dim color (fill under the line)
ROWS = [
    ("sleep", "SLP", "#6c9cff", "#121c33"),
    ("readiness", "RDY", "#3ddc97", "#0b2a1d"),
    ("activity", "ACT", "#ffa53d", "#2e1d0a"),
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

def points(y0, series):
    """(x, y) of each day's value, or None for a missing day."""
    vals = [v for v in series if v != None]
    if not vals:
        return [None] * len(series)
    lo, hi = min(vals), max(vals)
    if hi - lo < MIN_SPAN:
        mid = (lo + hi) / 2.0
        lo, hi = mid - MIN_SPAN / 2.0, mid + MIN_SPAN / 2.0
    n = len(series)
    out = []
    for i, v in enumerate(series):
        if v == None:
            out.append(None)
            continue
        x = CHART_X + int(i * (CHART_W - 1) / (n - 1) + 0.5) if n > 1 else CHART_X + CHART_W - 1
        y = y0 + CHART_H - int((v - lo) * (CHART_H - 1) / (hi - lo) + 0.5)
        out.append((x, y))
    return out

def line(a, b):
    """Pixels on the line from a to b; steep steps are filled so the line stays joined."""
    (x0, y0), (x1, y1) = a, b
    ys = [int(y0 + (y1 - y0) * (x - x0) / (x1 - x0) + 0.5) for x in range(x0, x1 + 1)]
    out = []
    for k, y in enumerate(ys):
        ny = ys[k + 1] if k + 1 < len(ys) else y
        out.append((x0 + k, y))
        # Climb toward the next column's y within this column.
        step = 1 if ny > y else -1
        for yy in range(y + step, ny, step):
            out.append((x0 + k, yy))
    return out

def arrow(x, y, up, color):
    rows = [(2, 1), (1, 3), (0, 5)]  # (x offset, width) per row, tip first
    return [pixel(x + dx, y + (i if up else 2 - i), color, w = w) for i, (dx, w) in enumerate(rows)]

def row(y0, spec, series, grow, glow):
    key, label, color, dim = spec
    kids = [text(0, y0 + 2, label, color)]
    bottom = y0 + CHART_H
    pts = points(y0, series)
    reveal = CHART_X + int(CHART_W * grow + 0.5)  # columns drawn so far

    # Faint fill under the line, then the line itself.
    seen = {}
    for k in range(len(pts) - 1):
        if pts[k] == None or pts[k + 1] == None:
            continue
        for x, y in line(pts[k], pts[k + 1]):
            if x >= reveal:
                continue
            if x not in seen or y < seen[x]:
                seen[x] = y
            kids.append(pixel(x, y, color))
    fill = [pixel(x, y + 1, dim, h = bottom - y) for x, y in seen.items() if y < bottom]
    kids = kids[:1] + fill + kids[1:]

    # Every day gets a point (so a day between two gaps still shows); missing
    # days show as a dim tick on the baseline; today is a bright dot.
    for k, p in enumerate(pts):
        if p != None and p[0] < reveal:
            kids.append(pixel(p[0], p[1], color))
        elif p == None:
            x = CHART_X + int(k * (CHART_W - 1) / max(1, len(pts) - 1) + 0.5)
            kids.append(pixel(x, bottom, "#333333"))
    last = pts[-1] if pts else None
    if last != None and grow >= 1.0:
        kids.append(pixel(last[0], last[1], "#ffffff" if glow else color))
        if glow:
            for dx, dy in ((-1, 0), (0, -1), (0, 1)):
                kids.append(pixel(last[0] + dx, last[1] + dy, color))

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

    frames = [frame(data, ease((i + 1) / DRAW_FRAMES), False) for i in range(DRAW_FRAMES)]

    # Hold: today's dot glows on and off. Reuse two frames to keep rendering fast.
    on, off = frame(data, 1.0, True), frame(data, 1.0, False)
    for i in range(HOLD_FRAMES):
        frames.append(on if (i // 8) % 2 == 0 else off)

    return render.Root(delay = DELAY_MS, show_full_animation = True, child = render.Animation(children = frames))
