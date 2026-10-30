"""
Oura for Tidbyt.
Three score rings, Oura style: sleep, readiness and activity. The rings fill up
when the widget comes on, then the tip of each ring glows. Under each ring:
its label, and last night's sleep time, HRV and today's steps.

The Lambda fetches the data from the Oura API and passes it in as JSON, so
the app itself needs no credentials.

Config:
  data   JSON: {"day", "sleep", "readiness", "activity", "sleep_secs", "hrv",
         "rhr", "steps"}; any value may be null. Without it, shows sample data.
"""

load("encoding/json.star", "json")
load("math.star", "math")
load("render.star", "render")

FONT = "tom-thumb"
R = 9  # ring radius; each ring is 19x19
RING_Y = 0
COLS = [0, 22, 44]  # left edge of each 20-px column
FILL_FRAMES = 20
HOLD_FRAMES = 130  # FILL + HOLD frames at 100 ms is about one rotation slot
DELAY_MS = 100

SAMPLE = {"day": "", "sleep": 84, "readiness": 77, "activity": 62, "sleep_secs": 27120, "hrv": 42, "rhr": 52, "steps": 8423}

RINGS = [
    # key, label, ring color, dim track color
    ("sleep", "SLEEP", "#6c9cff", "#16213a"),
    ("readiness", "READY", "#3ddc97", "#0f2e22"),
    ("activity", "MOVE", "#ffa53d", "#33220e"),
]

def pixel(x, y, color):
    return render.Padding(pad = (x, y, 0, 0), child = render.Box(width = 1, height = 1, color = color))

def ring_pixels():
    """Pixels of a 2-px ring, ordered clockwise from 12 o'clock."""
    pts = []
    for y in range(2 * R + 1):
        for x in range(2 * R + 1):
            dx, dy = x - R, y - R
            d = math.sqrt(dx * dx + dy * dy)
            if d < R - 1.6 or d > R + 0.4:
                continue
            a = math.atan2(dx, -dy)
            if a < 0:
                a += 2 * math.pi
            pts.append((a / (2 * math.pi), x, y))
    return sorted(pts)

RING = ring_pixels()

def ring(x0, score, frac, color, track, glow):
    """One ring: `frac` of the score drawn, plus the score number inside."""
    filled = 0.0 if score == None else score / 100.0 * frac
    kids = []
    tip = None
    for p, x, y in RING:
        if p < filled:
            kids.append(pixel(x0 + x, RING_Y + y, color))
            tip = (x, y)
        else:
            kids.append(pixel(x0 + x, RING_Y + y, track))
    if tip != None and glow:
        kids.append(pixel(x0 + tip[0], RING_Y + tip[1], "#ffffff"))

    if score == None:
        label, num_color = "--", "#666666"
    else:
        label = str(int(math.round(score * frac)))
        num_color = "#ff7a5c" if score < 70 else "#ffffff"
    kids.append(render.Padding(
        pad = (x0, RING_Y, 0, 0),
        child = render.Box(
            width = 2 * R + 1,
            height = 2 * R + 1,
            child = render.Padding(pad = (1, 1, 0, 0), child = render.Text(label, font = FONT, color = num_color)),
        ),
    ))
    return kids

def centered(x0, y, text, color):
    return render.Padding(
        pad = (x0, y, 0, 0),
        child = render.Box(width = 20, height = 6, child = render.Text(text, font = FONT, color = color)),
    )

def fmt_sleep(secs):
    if secs == None:
        return "--"
    m = int(secs) // 60
    mm = m % 60
    return "%dh%s%d" % (m // 60, "0" if mm < 10 else "", mm)

def fmt_steps(steps):
    if steps == None:
        return "--"
    if steps >= 10000:
        return "%dk" % (steps // 1000)
    if steps >= 1000:
        k = int(math.round(steps / 100.0))
        return "%d.%dk" % (k // 10, k % 10)
    return str(int(steps))

def frame(data, frac, glow):
    kids = []
    for i, (key, _, color, track) in enumerate(RINGS):
        kids.extend(ring(COLS[i], data.get(key), frac, color, track, glow))

    hrv = data.get("hrv")
    stats = [
        fmt_sleep(data.get("sleep_secs")),
        "--" if hrv == None else "HRV%d" % int(hrv),
        fmt_steps(data.get("steps")),
    ]
    for i, (_, label, color, _) in enumerate(RINGS):
        kids.append(centered(COLS[i], 20, label, color))
        kids.append(centered(COLS[i], 26, stats[i], "#bbbbbb"))
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

    frames = [frame(data, ease(i / (FILL_FRAMES - 1)), False) for i in range(FILL_FRAMES)]

    # Hold: the ring tips glow on and off. Reuse two frames to keep rendering fast.
    on, off = frame(data, 1.0, True), frame(data, 1.0, False)
    for i in range(HOLD_FRAMES):
        frames.append(on if (i // 10) % 2 == 0 else off)

    return render.Root(delay = DELAY_MS, show_full_animation = True, child = render.Animation(children = frames))
