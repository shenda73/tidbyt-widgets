"""
Sectors for Tidbyt.
What is moving today, by sector. The eleven S&P 500 sectors stand side by
side as bars, strongest on the left: up from the baseline in green, down in
red, brighter toward the tip. The dotted line is the S&P 500 itself, so bars
that reach past it are beating the market; the header starts with its change. A sector trading at an unusually
high volume for the time of day has an amber tip.

A highlight walks along the bars; the header names the lit sector with its
change since the previous close and its volume pace (1.0x is normal).

The bars grow from the baseline when the widget comes on.

Data comes from Yahoo Finance's chart API for the sector SPDR funds (XLK,
XLF and so on), which needs no key.

Config (all optional):
  unusual  volume pace from which a sector gets an amber tip (default 1.5)
"""

load("http.star", "http")
load("math.star", "math")
load("render.star", "render")
load("time.star", "time")

URLS = [
    "https://query1.finance.yahoo.com/v8/finance/chart/{}?range=3mo&interval=1d",
    "https://query2.finance.yahoo.com/v8/finance/chart/{}?range=3mo&interval=1d",
]
HEADERS = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"}

MARKET = "SPY"
SECTORS = [
    ("XLK", "TECH"),
    ("XLC", "COMM"),
    ("XLY", "DISC"),
    ("XLF", "FIN"),
    ("XLV", "HLTH"),
    ("XLI", "INDU"),
    ("XLP", "STPL"),
    ("XLE", "ENRG"),
    ("XLU", "UTIL"),
    ("XLB", "MATL"),
    ("XLRE", "REIT"),
]

W = 64
FONT = "tom-thumb"
TOP = 8  # chart rows 8..31
ROWS = 24
BAR_W, BAR_GAP = 4, 2  # 11 bars fill the 64 columns exactly
MIN_SPAN = 1.0  # least percent range shown, so a quiet day stays quiet
DELAY_MS = 100
INTRO = 18  # frames for the bars to grow
STEP = 12  # frames the highlight spends on each sector
AVG_DAYS = 20

UP_LOW, UP = "#0c3d22", "#2fe07a"
DOWN_LOW, DOWN = "#4a1219", "#ff4d5e"
HOT = "#ffb020"
BASELINE = "#3c3c3c"
MARKET_LINE = "#707070"

# Share of a day's volume usually done by each point of the session: trading
# is heaviest at the open and the close. (session fraction, volume fraction)
VOLUME_CURVE = [(0.0, 0.0), (0.08, 0.15), (0.25, 0.33), (0.5, 0.52), (0.75, 0.70), (0.92, 0.85), (1.0, 1.0)]

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

def fetch(symbol):
    for url in URLS:
        resp = http.get(url.format(symbol), headers = HEADERS)
        if resp.status_code == 200:
            result = resp.json().get("chart", {}).get("result")
            if result:
                return result[0]
    return None

def expected_share(meta):
    """Share of a normal day's volume that should be done by now."""
    period = meta.get("currentTradingPeriod", {}).get("regular")
    now = time.now().unix
    if not period or now < period["start"] or now >= period["end"]:
        return 1.0  # outside the session the last bar is a full day
    x = (now - period["start"]) / (period["end"] - period["start"])
    for i in range(1, len(VOLUME_CURVE)):
        x0, y0 = VOLUME_CURVE[i - 1]
        x1, y1 = VOLUME_CURVE[i]
        if x <= x1:
            return max(0.02, y0 + (y1 - y0) * (x - x0) / (x1 - x0))
    return 1.0

def study(symbol):
    """Change since the previous close (percent) and volume pace."""
    chart = fetch(symbol)
    if chart == None:
        return None
    q = (chart.get("indicators", {}).get("quote") or [{}])[0]
    bars = [(c, v or 0) for c, v in zip(q.get("close") or [], q.get("volume") or []) if c != None]
    if len(bars) < 2:
        return None

    price = chart["meta"].get("regularMarketPrice") or bars[-1][0]
    prev = bars[-2][0]

    before = [v for _, v in bars[-1 - AVG_DAYS:-1] if v > 0]
    pace = None
    if before and bars[-1][1] > 0:
        mean = 0
        for v in before:
            mean += v
        pace = bars[-1][1] / (mean / len(before) * expected_share(chart["meta"]))
    return {"pct": (price - prev) / prev * 100, "pace": pace}

def pct_text(pct):
    a = abs(pct)
    if a < 0.05:
        return "0.0%"
    sign = "+" if pct >= 0 else "-"
    if a >= 9.95:
        return "%s%d%%" % (sign, int(math.round(a)))
    n = int(math.round(a * 10))
    return "%s%d.%d%%" % (sign, n // 10, n % 10)

def pace_text(pace):
    if pace >= 9.95:
        return "%dx" % int(math.round(pace))
    n = int(math.round(pace * 10))
    return "%d.%dx" % (n // 10, n % 10)

def volume_icon(color):
    """Three small bars, as a label for the volume pace."""
    return render.Stack(children = [
        render.Box(width = 5, height = 6),
        px(0, 3, color, h = 2),
        px(2, 1, color, h = 4),
        px(4, 2, color, h = 3),
    ])

def pct_color(pct):
    if abs(pct) < 0.05:
        return "#aaaaaa"
    return UP if pct > 0 else DOWN

def header(name, pct, pace, unusual):
    color = pct_color(pct)
    right = []
    if pace != None:
        pace_color = HOT if pace >= unusual else "#8a8a8a"
        right = [
            volume_icon(pace_color),
            render.Box(width = 1, height = 1),
            render.Text(pace_text(pace), font = FONT, color = pace_color),
        ]
    return render.Row(
        expanded = True,
        main_align = "space_between",
        children = [
            render.Text(name, font = FONT, color = "#ffffff"),
            render.Text(pct_text(pct), font = FONT, color = color),
            render.Row(children = right),
        ],
    )

def bar(n, s, zero, scale, grow, light, unusual):
    """Bar n at `grow` (0..1) of its length; `light` (0..1) is how lit it is."""
    x = n * (BAR_W + BAR_GAP)
    up = s["pct"] >= 0
    length = max(1, int(abs(s["pct"]) * scale * grow + 0.5))
    low, high = (UP_LOW, UP) if up else (DOWN_LOW, DOWN)
    hot = s["pace"] != None and s["pace"] >= unusual

    out = []
    for k in range(length):
        # k counts rows from the baseline to the tip.
        y = zero - 1 - k if up else zero + 1 + k
        if y < 0 or y >= ROWS:
            continue
        color = lerp_color(low, high, (k + 1) / length)
        if hot and k == length - 1 and grow >= 1.0:
            color = HOT
        color = lerp_color("#000000", color, 0.55 + 0.45 * light)
        out.append(px(x, TOP + y, color, w = BAR_W))
    return out

def main(config):
    unusual = float(config.get("unusual", "1.5"))

    market = study(MARKET)
    sectors = []
    for symbol, name in SECTORS:
        s = study(symbol)
        if s != None:
            s["name"] = name
            sectors.append(s)
    if not sectors:
        return render.Root(child = render.Box(child = render.Text("no data", font = FONT, color = "#f55")))
    sectors = sorted(sectors, key = lambda s: s["pct"], reverse = True)

    # Vertical scale: the baseline sits where zero falls between the best
    # and the worst sector. One row is kept for the baseline itself.
    best = max(0.0, sectors[0]["pct"])
    worst = min(0.0, sectors[-1]["pct"])
    span = max(best - worst, MIN_SPAN)
    scale = (ROWS - 1) / span  # rows per percent
    zero = clamp(int(best * scale + 0.5), 0, ROWS - 1)

    backdrop = [px(0, TOP + zero, BASELINE, w = W)]
    if market != None:
        y = zero - int(math.round(market["pct"] * scale))
        if y != zero and 0 <= y and y < ROWS:
            for x in range(1, W, 3):
                backdrop.append(px(x, TOP + y, MARKET_LINE))
    backdrop = render.Stack(children = backdrop)

    title = render.Row(
        expanded = True,
        main_align = "space_between",
        children = [
            render.Text("S&P 500" if market != None else "SECTORS", font = FONT, color = "#ffffff"),
            render.Text(pct_text(market["pct"]), font = FONT, color = pct_color(market["pct"])) if market != None else render.Box(width = 1, height = 1),
        ],
    )

    frames = []
    for i in range(INTRO + STEP * len(sectors)):
        kids = [backdrop]
        if i < INTRO:
            # Bars grow from the baseline, left to right.
            kids.append(title)
            for n, s in enumerate(sectors):
                grow = ease_out((i + 1 - n * 0.8) / 9)
                if grow > 0:
                    kids += bar(n, s, zero, scale, grow, 0.6, unusual)
        else:
            # The highlight glides from one bar to the next.
            k = i - INTRO
            lit, into = k // STEP, (k % STEP) / STEP
            s = sectors[lit]
            kids.append(header(s["name"], s["pct"], s["pace"], unusual))
            for n, other in enumerate(sectors):
                light = 0.0
                if n == lit:
                    light = min(1.0, into * 4)
                elif n == lit - 1:
                    light = max(0.0, 1.0 - into * 4)
                kids += bar(n, other, zero, scale, 1.0, light, unusual)

            # A white mark under (or over) the lit bar, on the baseline.
            kids.append(px(lit * (BAR_W + BAR_GAP), TOP + zero, "#ffffff", w = BAR_W))
        frames.append(render.Stack(children = kids))

    return render.Root(delay = DELAY_MS, child = render.Animation(children = frames))
