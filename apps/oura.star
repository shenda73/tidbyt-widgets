"""
Oura ticker for Tidbyt.
A Wall Street style ticker wall: three rows of Oura signals scroll by, each
with today's value, the change since yesterday (green when it's good news, red
when it's not) and a 7-day sparkline.

  row 1  scores    sleep, readiness, activity
  row 2  body      HRV, resting HR, temperature, breathing, SpO2
  row 3  day       steps, active calories, stress, deep sleep, efficiency, bedtime

The Lambda fetches the data from the Oura API and passes it in as JSON, so
the app itself needs no credentials.

Config:
  data   JSON: {"series": {name: [7 values, oldest first, null when missing]},
         "bed": "HH:MM"}. Without it, shows sample data.
"""

load("encoding/json.star", "json")
load("render.star", "render")

FONT = "tom-thumb"  # monospaced: 4 px per character
CH = 4
FRAMES = 300
DELAY_MS = 50  # 1 px per frame = 20 px/s; FRAMES * DELAY_MS = 15 s
ROW_Y = [0, 11, 22]
ROW_START = [0, 37, 74]  # stagger the rows so items don't line up
LINE = "#1c1c1c"
UP, DOWN, FLAT = "#2ee86a", "#ff4d4d", "#888888"

# Signals, row by row: (series key, label, label color, format, better, show delta).
# better: 1 if higher is good, -1 if lower is good, 0 if neither.
ROWS = [
    [
        ("sleep", "SLEEP", "#6c9cff", "int", 1, True),
        ("readiness", "READY", "#3ddc97", "int", 1, True),
        ("activity", "ACTV", "#ffa53d", "int", 1, True),
    ],
    [
        ("hrv", "HRV", "#c792ea", "int", 1, True),
        ("rhr", "RHR", "#ff6b8b", "int", -1, True),
        ("temp", "TEMP", "#ffcb6b", "temp", 0, True),
        ("breath", "BRTH", "#89ddff", "dec", 0, True),
        ("spo2", "SPO2", "#ff8f8f", "pct", 1, True),
    ],
    [
        ("steps", "STEPS", "#ffa53d", "k", 1, False),
        ("cal", "CAL", "#f78c6c", "int", 1, False),
        ("stress", "STRESS", "#ff6b6b", "min", -1, False),
        ("deep", "DEEP", "#6c9cff", "hm", 1, True),
        ("eff", "EFF", "#82aaff", "pct", 1, True),
    ],
]

SAMPLE = {
    "series": {
        "sleep": [78, 82, 75, 88, 80, 84, 87],
        "readiness": [70, 74, 79, 83, 85, 83, 81],
        "activity": [60, 72, 55, 80, 66, 62, 67],
        "hrv": [38, 41, 35, 44, 40, 39, 42],
        "rhr": [54, 53, 56, 52, 53, 53, 52],
        "temp": [0.1, -0.2, 0.0, 0.3, -0.1, 0.0, 0.2],
        "breath": [14.8, 15.0, 14.6, 14.9, 15.1, 14.7, 14.5],
        "spo2": [97, 96, 97, 98, 97, 97, 97],
        "steps": [9800, 12040, 6100, 10350, 8800, 7900, 3200],
        "cal": [420, 560, 300, 510, 380, 360, 150],
        "stress": [95, 120, 60, 45, 80, 110, 30],
        "deep": [4800, 5400, 4200, 6000, 5100, 4900, 5700],
        "eff": [88, 91, 86, 93, 89, 90, 92],
    },
    "bed": "23:41",
}

def pixel(x, y, color, w = 1, h = 1):
    return render.Padding(pad = (x, y, 0, 0), child = render.Box(width = w, height = h, color = color))

def text(s, color):
    return render.Text(s, font = FONT, color = color)

def fmt(v, kind):
    if v == None:
        return "--"
    if kind == "int":
        return str(int(v + 0.5))
    if kind == "pct":
        return str(int(v + 0.5)) + "%"
    if kind == "dec" or kind == "temp":
        t = int(abs(v) * 10 + 0.5)
        s = "%d.%d" % (t // 10, t % 10)
        if kind == "temp":
            return ("-" if v < 0 and t > 0 else "+") + s
        return s
    if kind == "k":
        if v >= 1000:
            t = int(v / 100 + 0.5)
            return "%d.%dk" % (t // 10, t % 10)
        return str(int(v))
    if kind == "min":
        return str(int(v)) + "m"
    if kind == "hm":
        m = int(v) // 60
        mm = m % 60
        return "%d:%s%d" % (m // 60, "0" if mm < 10 else "", mm)
    return str(v)

def last_two(series):
    """Latest value and the one before it, skipping gaps."""
    vals = [v for v in series if v != None]
    if not vals:
        return None, None
    return vals[-1], (vals[-2] if len(vals) > 1 else None)

def arrow(up, color):
    rows = [(2, 1), (1, 3), (0, 5)]  # (x offset, width) per row, tip first
    kids = []
    for i, (x, w) in enumerate(rows):
        kids.append(pixel(x, i if up else 2 - i, color, w = w))
    return render.Padding(pad = (0, 1, 0, 0), child = render.Stack(children = [render.Box(width = 5, height = 3)] + kids))

def sparkline(series, color):
    vals = [v for v in series if v != None]
    if len(vals) < 2:
        return render.Box(width = 7, height = 6)
    lo, hi = min(vals), max(vals)
    span = hi - lo if hi > lo else 1
    kids = [render.Box(width = 7, height = 6)]
    n = len(series)
    prev = None
    for i, v in enumerate(series):
        if v == None:
            prev = None
            continue
        x = 7 - n + i
        y = 5 - int((v - lo) * 5.0 / span + 0.5)
        if prev != None and abs(y - prev) > 1:
            # Fill the jump from the previous point so it reads as a line.
            kids.append(pixel(x, min(y, prev) + 1, color, h = abs(y - prev) - 1))
        kids.append(pixel(x, y, "#ffffff" if i == n - 1 else color))
        prev = y
    return render.Stack(children = kids)

def item(sig, series):
    key, label, color, kind, better, show_delta = sig
    cur, prev = last_two(series)
    parts = [text(label, color), render.Box(width = 2, height = 1), text(fmt(cur, kind), "#ffffff")]
    width = CH * len(label) + 2 + CH * len(fmt(cur, kind))

    if show_delta and cur != None and prev != None:
        d = cur - prev
        if kind == "hm":
            d = d / 60  # seconds -> minutes
            dtxt = str(int(abs(d) + 0.5)) + "m"
        elif kind in ("dec", "temp"):
            dtxt = fmt(abs(d), "dec")
        else:
            dtxt = str(int(abs(d) + 0.5))
        if dtxt in ("0", "0m", "0.0"):
            c, a = FLAT, None
        else:
            good = d * better > 0
            c = FLAT if better == 0 else (UP if good else DOWN)
            a = arrow(d > 0, c)
        parts.append(render.Box(width = 2, height = 1))
        width += 2
        if a != None:
            parts += [a, render.Box(width = 1, height = 1)]
            width += 6
        parts.append(text(dtxt, c))
        width += CH * len(dtxt)

    parts += [render.Box(width = 2, height = 1), sparkline(series, color)]
    width += 9

    # Separator before the next item.
    parts += [render.Box(width = 4, height = 1), render.Padding(pad = (0, 1, 0, 0), child = render.Box(width = 1, height = 4, color = "#333333")), render.Box(width = 4, height = 1)]
    width += 9
    return render.Row(children = parts), width

def ticker_row(sigs, data, with_bed):
    series = data.get("series", {})
    items, total = [], 0
    for sig in sigs:
        if sig[0] not in series or not [v for v in series[sig[0]] if v != None]:
            continue  # skip signals we have no data for
        w, n = item(sig, series[sig[0]])
        items.append(w)
        total += n
    if with_bed and data.get("bed"):
        bed = data["bed"]
        items.append(render.Row(children = [
            text("BED", "#c3a6ff"),
            render.Box(width = 2, height = 1),
            text(bed, "#ffffff"),
            render.Box(width = 4, height = 1),
            render.Padding(pad = (0, 1, 0, 0), child = render.Box(width = 1, height = 4, color = "#333333")),
            render.Box(width = 4, height = 1),
        ]))
        total += CH * 3 + 2 + CH * len(bed) + 9
    if not items:
        return None, 0

    # Repeat the row until it covers the screen plus one full scroll.
    reps = (64 + FRAMES) // total + 2
    return render.Row(children = items * reps), total

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

    rows = [ticker_row(sigs, data, i == 2) for i, sigs in enumerate(ROWS)]
    lines = [pixel(0, ROW_Y[1] - 1, LINE, w = 64), pixel(0, ROW_Y[2] - 1, LINE, w = 64)]

    frames = []
    for f in range(FRAMES):
        kids = list(lines)
        for r, (row, total) in enumerate(rows):
            if row == None:
                continue
            x = (f + ROW_START[r]) % total
            kids.append(render.Padding(pad = (-x, ROW_Y[r] + 2, 0, 0), child = row))
        frames.append(render.Stack(children = kids))

    return render.Root(delay = DELAY_MS, show_full_animation = True, child = render.Animation(children = frames))
