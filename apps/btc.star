"""
Bitcoin tracker for Tidbyt.
The price of one bitcoin in dollars, and where it has been: the chart opens
on the last 24 hours, then zooms out to the last 7 days and the last 30 days.
The right edge is always now, so each zoom squeezes the chart you were looking
at into the right-hand side while the earlier days slide in from the left.

The percentage is the change over the span on screen, and it rolls as the
chart zooms. The line is green when the price is up over that span and red
when it is down; the gray dotted line is the price at the start of the span.

Data comes from Coinbase's public market data API, which needs no key. If
Coinbase cannot be reached, Yahoo Finance's hourly prices are used instead.

Config (all optional):
  seconds  seconds on screen per span (default 5)
"""

load("http.star", "http")
load("math.star", "math")
load("render.star", "render")
load("time.star", "time")

COINBASE_URL = "https://api.exchange.coinbase.com/products/BTC-USD/candles?granularity={}"
YAHOO_URL = "https://query1.finance.yahoo.com/v8/finance/chart/BTC-USD?range=1mo&interval=1h"
HEADERS = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"}

DAY = 86400

# Candle sizes to fetch, finest first. Each call returns about 350 candles:
# 29 hours of 5-minute ones, two weeks of hourly ones, 87 days of 6-hour ones.
CANDLES = [300, 3600, 21600]

# (tab, seconds, x of the tab in the header)
SPANS = [("24H", DAY, 0), ("7D", 7 * DAY, 14), ("30D", 30 * DAY, 24)]

W = 64
FONT = "tom-thumb"
PRICE_FONT = "tb-8"
TOP = 15  # chart rows 15..31, under two rows of text
ROWS = 17
GLOW_ROWS = 8
DELAY_MS = 100
DRAW = 16  # frames for the first line to draw in
ZOOM = 14  # frames for each zoom out
SWAP = 0.25  # share of a zoom, around its middle, in which the lit tab changes

UP, DOWN = "#2fe07a", "#ff4d5e"
ORANGE = "#f7931a"
LIT, DIM = "#ffffff", "#4a4a4a"
START_LINE = "#3a3a3a"

# The bitcoin mark, 7x7: "o" is the coin, "B" the letter on it.
COIN = [
    ".ooooo.",
    "ooBBooo",
    "ooBoBoo",
    "ooBBooo",
    "ooBoBoo",
    "ooBBooo",
    ".ooooo.",
]

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

def ease_in_out(t):
    t = clamp(t, 0.0, 1.0)
    if t < 0.5:
        return 4 * t * t * t
    return 1.0 - math.pow(2.0 - 2.0 * t, 3) / 2

def px(x, y, color, w = 1, h = 1):
    return render.Padding(
        pad = (x, y, 0, 0),
        child = render.Box(width = w, height = h, color = color),
    )

def coinbase(now):
    """(time, price) pairs, oldest first: 6-hour steps far back, hourly
    closer in, 5-minute steps for the last day. None if a call fails."""
    series = []
    for size in CANDLES:
        resp = http.get(COINBASE_URL.format(size), headers = HEADERS)
        if resp.status_code != 200:
            return None
        candles = resp.json()
        if type(candles) != "list" or len(candles) < 2:
            return None

        # Candles come newest first as [start, low, high, open, close,
        # volume]. Keep the ones older than what the finer sizes cover.
        oldest = series[0][0] if series else now + 1
        older = []
        for c in candles:
            t = min(int(c[0]) + size, now)  # a candle's close is at its end
            if t < oldest:
                older.append((t, float(c[4])))
        series = list(reversed(older)) + series
    return series

def yahoo(now):
    """Hourly (time, price) pairs for the last month, ending at the latest price."""
    resp = http.get(YAHOO_URL, headers = HEADERS)
    if resp.status_code != 200:
        return None
    result = resp.json().get("chart", {}).get("result")
    if not result:
        return None
    stamps = result[0].get("timestamp") or []
    closes = (result[0].get("indicators", {}).get("quote") or [{}])[0].get("close") or []
    series = [(int(t), float(c)) for t, c in zip(stamps, closes) if c != None and t < now]
    price = result[0]["meta"].get("regularMarketPrice")
    if price:
        series.append((now, float(price)))
    return series if len(series) >= 2 else None

def price_at(series, t):
    """The price at time t, between the two points around it."""
    if t <= series[0][0]:
        return series[0][1]
    for i in range(1, len(series)):
        t1, p1 = series[i]
        if t <= t1:
            t0, p0 = series[i - 1]
            return p0 + (p1 - p0) * (t - t0) / (t1 - t0) if t1 > t0 else p1
    return series[-1][1]

def sample(series, start, end, n):
    """n prices evenly spread over start..end. Each is the mean of the
    points in its slice of time, so a squeezed stretch of chart stays steady
    while it zooms; a slice with no points takes the price at its middle."""
    step = (end - start) / (n - 1)
    out = []
    j = 0  # the first point after the start of the current slice
    for x in range(n):
        t = start + x * step
        for _ in range(len(series)):
            if j >= len(series) or series[j][0] > t - step / 2:
                break
            j += 1
        total, count, k = 0.0, 0, j
        for _ in range(len(series)):
            if k >= len(series) or series[k][0] > t + step / 2:
                break
            total += series[k][1]
            count += 1
            k += 1
        if count:
            out.append(total / count)
        elif j == 0:
            out.append(series[0][1])
        elif j >= len(series):
            out.append(series[-1][1])
        else:
            t0, p0 = series[j - 1]
            t1, p1 = series[j]
            out.append(p0 + (p1 - p0) * (t - t0) / (t1 - t0))
    return out

def window(series, now, span):
    """The chart of the last `span` seconds: a row per column, the row of
    the price at the start of the span, and the change over the span."""
    prices = sample(series, now - span, now, W)
    prices[-1] = series[-1][1]
    first = price_at(series, now - span)
    hi, lo = max(prices), min(prices)
    if hi == lo:
        hi, lo = hi + 0.01, lo - 0.01

    def row(p):
        return clamp(int((hi - p) / (hi - lo) * (ROWS - 1) + 0.5), 0, ROWS - 1)

    return [row(p) for p in prices], row(first), (prices[-1] - first) / first * 100

def chart(rows, start_row, color, shown):
    """The chart up to column `shown`; returns widgets and the tip position."""
    out = []

    # A glow hangs under the line: brightest right below it, fading to
    # black GLOW_ROWS further down.
    for depth in range(1, GLOW_ROWS + 1):
        fill = lerp_color("#000000", color, 0.5 * math.pow(1.0 - (depth - 1) / GLOW_ROWS, 1.5))
        run = None
        for x in range(shown + 1):
            y = rows[x] + depth if x < shown else None
            if run != None and y != run[1]:
                if run[1] < ROWS:
                    out.append(px(run[0], TOP + run[1], fill, w = x - run[0]))
                run = None
            if y != None and run == None:
                run = (x, y)

    # The price at the start of the span, dotted.
    for x in range(1, W, 3):
        out.append(px(x, TOP + start_row, START_LINE))

    # The line itself, joined with vertical runs.
    last = None
    for x in range(shown):
        y = rows[x]
        y0, y1 = (y, y) if last == None else (min(y, last), max(y, last))
        if last != None and y != last:
            if y > last:
                y0 += 1
            else:
                y1 -= 1
        out.append(px(x, TOP + y0, color, h = y1 - y0 + 1))
        last = y
    return out, (shown - 1, TOP + last)

def fmt(x, decimals):
    """Fixed-point number with thousands separators (no %.Nf in Starlark)."""
    scale = int(math.pow(10, decimals))
    n = int(math.round(abs(x) * scale))
    whole, frac = n // scale, n % scale
    s = str(whole)
    groups = []
    for _ in range(6):
        if len(s) <= 3:
            break
        groups.insert(0, s[-3:])
        s = s[:-3]
    groups.insert(0, s)
    out = ",".join(groups)
    if decimals > 0:
        f = str(frac)
        out += "." + "0" * (decimals - len(f)) + f
    return out

def pct_text(pct):
    a = abs(pct)
    return ("+" if pct >= 0 else "-") + fmt(a, 2 if a < 9.995 else (1 if a < 99.95 else 0)) + "%"

def coin():
    out = []
    for y, line in enumerate(COIN):
        for x in range(len(line)):
            if line[x] != ".":
                out.append(px(x, y, ORANGE if line[x] == "o" else "#ffffff"))
    return out

def header(price, pct, color, at):
    """The coin and the price; below, the three spans and the change over
    the one on screen. `at` is the lit tab: 1.5 is halfway from 1 to 2."""
    out = coin()
    out.append(render.Row(
        expanded = True,
        main_align = "end",
        children = [render.Text(fmt(price, 0 if price >= 1000 else 2), font = PRICE_FONT, color = "#ffffff")],
    ))
    for n, (tab, _, x) in enumerate(SPANS):
        out.append(render.Padding(
            pad = (x, 9, 0, 0),
            child = render.Text(tab, font = FONT, color = lerp_color(LIT, DIM, abs(at - n))),
        ))
    out.append(render.Padding(
        pad = (0, 9, 0, 0),
        child = render.Row(
            expanded = True,
            main_align = "end",
            children = [render.Text(pct_text(pct), font = FONT, color = color)],
        ),
    ))
    return out

def frame(series, now, span, at, shown = W):
    """One picture: the header and the chart of the last `span` seconds.
    Returns the widgets and the position of the latest price."""
    rows, start_row, pct = window(series, now, span)
    color = UP if pct >= 0 else DOWN
    kids = header(series[-1][1], pct, color, at)
    part, tip = chart(rows, start_row, color, shown)
    return kids + part, tip

def main(config):
    seconds = int(config.get("seconds", "5"))
    hold = max(10, seconds * 1000 // DELAY_MS)

    now = time.now().unix
    series = coinbase(now) or yahoo(now)
    if not series:
        return render.Root(child = render.Box(child = render.Text("no data", font = FONT, color = "#f55")))

    frames = []
    for n, (_, span, _) in enumerate(SPANS):
        moving = 0
        if n == 0:
            # The first line draws in from the left.
            moving = DRAW
            for i in range(DRAW):
                shown = max(1, int(ease_out((i + 1) / DRAW) * W + 0.5))
                kids, tip = frame(series, now, span, n, shown)
                kids.append(px(tip[0], tip[1], "#ffffff"))
                frames.append(render.Stack(children = kids))
        else:
            # Zoom out from the previous span; the lit tab hands over
            # around the middle.
            moving = ZOOM
            before = SPANS[n - 1][1]
            for i in range(ZOOM):
                e = ease_in_out((i + 1) / (ZOOM + 1))
                between = before * math.pow(span / before, e)
                at = n - 1 + clamp((e - 0.5) / SWAP + 0.5, 0.0, 1.0)
                kids, tip = frame(series, now, between, at)
                kids.append(px(tip[0], tip[1], "#ffffff"))
                frames.append(render.Stack(children = kids))

        # Hold: the latest price breathes.
        kids, tip = frame(series, now, span, n)
        still = render.Stack(children = kids)
        x, y = tip
        for i in range(max(10, hold - moving)):
            pulse = 0.5 - 0.5 * math.cos(2 * math.pi * i / 16)
            halo = lerp_color("#000000", "#ffffff", 0.12 + 0.3 * pulse)
            kids = [still]
            for dx, dy in [(-1, 0), (0, -1), (0, 1)]:
                if TOP <= y + dy and y + dy < TOP + ROWS:
                    kids.append(px(x + dx, y + dy, halo))
            kids.append(px(x, y, "#ffffff"))
            frames.append(render.Stack(children = kids))

    return render.Root(delay = DELAY_MS, child = render.Animation(children = frames))
