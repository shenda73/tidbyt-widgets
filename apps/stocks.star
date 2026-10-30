"""
Stock watch for Tidbyt.
Cycles through a list of tickers. Each one shows its price, the change since
the previous close and an intraday sparkline with a
blinking dot on the latest price. The chart
spans the whole trading session, so the line grows across the day, and a
dotted line marks the previous close.

Data comes from Yahoo Finance's chart API, which needs no key. When Yahoo's
feed for a stock is stale, the chart and price come from Nasdaq's instead.

Config:
  tickers  comma-separated Yahoo symbols, each optionally "SYMBOL:Label",
           e.g. "^GSPC:S&P,TSLA,SPCX". Default is S&P 500, Tesla, SpaceX.
  seconds  seconds on screen per ticker (default 5)
"""

load("http.star", "http")
load("math.star", "math")
load("render.star", "render")
load("time.star", "time")

DEFAULT_TICKERS = "^GSPC:S&P,TSLA,SPCX"
URLS = [
    "https://query1.finance.yahoo.com/v8/finance/chart/{}?range={}&interval={}",
    "https://query2.finance.yahoo.com/v8/finance/chart/{}?range={}&interval={}",
]
HEADERS = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"}

DELAY_MS = 100
CHART_TOP = 16
CHART_H = 16  # rows 16..31
WIDTH = 64
BAR_SECS = 300  # Yahoo's 5-minute bars
STALE_SECS = 15 * 60
NASDAQ_URL = "https://api.nasdaq.com/api/quote/{}/chart?assetclass=stocks"
NASDAQ_HEADERS = {"User-Agent": HEADERS["User-Agent"], "Accept": "application/json"}

UP, DOWN, FLAT = "#2fe07a", "#ff4d5e", "#aaaaaa"
INK, MUTED, BASELINE = "#f4f4f4", "#777777", "#4a4a4a"
HEX = "0123456789abcdef"

def fetch(symbol, rng, interval):
    for url in URLS:
        resp = http.get(url.format(symbol.replace("^", "%5E"), rng, interval), headers = HEADERS)
        if resp.status_code == 200:
            result = resp.json().get("chart", {}).get("result")
            if result:
                return result[0]
    return None

def session_points(chart):
    """(timestamp, close) pairs of the last trading day in the chart."""
    stamps = chart.get("timestamp") or []
    quotes = chart.get("indicators", {}).get("quote") or [{}]
    closes = quotes[0].get("close") or []
    tz = chart["meta"].get("exchangeTimezoneName", "America/New_York")
    pts = [(t, c) for t, c in zip(stamps, closes) if c != None]
    if not pts:
        return []
    last_day = time.from_timestamp(int(pts[-1][0])).in_location(tz).format("2006-01-02")
    return [p for p in pts if time.from_timestamp(int(p[0])).in_location(tz).format("2006-01-02") == last_day]

def quote(symbol):
    chart = fetch(symbol, "1d", "5m")
    if chart == None:
        return None
    meta = chart["meta"]
    prev = meta.get("chartPreviousClose") or meta.get("previousClose")
    pts = session_points(chart)

    # Before the open, the 1-day range can be empty: show the last session instead.
    if len(pts) < 2:
        older = fetch(symbol, "5d", "5m")
        if older != None:
            pts = session_points(older)
            closes = [c for _, c in pts]
            all_closes = [c for c in (older.get("indicators", {}).get("quote") or [{}])[0].get("close") or [] if c != None]
            n = len(all_closes) - len(closes)
            if n > 0:
                prev = all_closes[n - 1]

    price = meta.get("regularMarketPrice")
    if price == None and pts:
        price = pts[-1][1]
    if price == None:
        return None

    # Session start and end, for the chart's x axis.
    start, end = None, None
    period = meta.get("currentTradingPeriod", {}).get("regular")
    if period and pts and period["start"] <= pts[-1][0] and pts[0][0] < period["end"]:
        start, end = period["start"], period["end"]
    elif pts:
        # Assume a 6.5-hour session starting at the first point.
        start = pts[0][0]
        end = start + 390 * 60
    q = {"price": price, "prev": prev, "pts": pts, "start": start, "end": end, "bar": BAR_SECS}

    # Yahoo's feed sometimes runs an hour or more behind for some stocks
    # (SPCX). If its last trade is stale during the session, use Nasdaq's.
    now = time.now().unix
    last_trade = meta.get("regularMarketTime") or 0
    if start != None and not symbol.startswith("^") and start < now and min(now, end) - last_trade > STALE_SECS:
        nq = nasdaq_points(symbol, start, end)
        if nq and nq[-1][0] > last_trade:
            q["pts"], q["price"], q["bar"] = nq, nq[-1][1], 60
    return q

def nasdaq_points(symbol, start, end):
    """Regular-session 1-minute (timestamp, price) pairs from Nasdaq, or None."""
    resp = http.get(NASDAQ_URL.format(symbol), headers = NASDAQ_HEADERS)
    if resp.status_code != 200:
        return None
    data = resp.json().get("data") or {}
    chart = data.get("chart") or []

    # Nasdaq's x is New York wall-clock time written as if it were UTC.
    offset = time.from_timestamp(int(start)).in_location("America/New_York").format("-0700")
    shift = (int(offset[1:3]) * 3600 + int(offset[3:5]) * 60) * (1 if offset[0] == "-" else -1)
    pts = []
    for p in chart:
        if p.get("x") == None or p.get("y") == None:
            continue
        t = int(p["x"] // 1000) + shift
        if start <= t and t < end:
            pts.append((t, float(p["y"])))
    return pts if len(pts) >= 2 else None

def fmt(x, decimals):
    """Fixed-point number with thousands separators (no %.Nf in Starlark)."""
    neg = x < 0
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
    return ("-" if neg else "") + out

def fmt_price(p):
    return fmt(p, 0 if p >= 10000 else 2)

def signed(x, decimals):
    return ("+" if x >= 0 else "") + fmt(x, decimals)

def mix(a, b, t):
    """Blend hex colors a -> b by t in [0, 1]."""
    out = "#"
    for i in (1, 3, 5):
        va, vb = int(a[i:i + 2], 16), int(b[i:i + 2], 16)
        v = max(0, min(255, int(va + (vb - va) * t + 0.5)))
        out += HEX[v // 16] + HEX[v % 16]
    return out

def box(x, y, w, h, color):
    return render.Padding(pad = (x, y, 0, 0), child = render.Box(width = w, height = h, color = color))

def column(x, top, h, color):
    return box(x, top, 1, h, color)

def chart_layers(q, color):
    """Layers of the area chart, and the (x, y) of the latest point."""
    pts, prev = q["pts"], q["prev"]
    if len(pts) < 2:
        return [], None
    vals = [c for _, c in pts]
    lo, hi = min(vals), max(vals)
    if prev != None:
        lo, hi = min(lo, prev), max(hi, prev)
    if hi - lo < 1e-9:
        hi = lo + 1

    def y_of(v):
        return CHART_TOP + int(math.round((hi - v) / (hi - lo) * (CHART_H - 1)))

    span = q["end"] - q["start"]

    # Last point that lands in each column. Timestamps are bar starts, so
    # the first bar (9:30) maps to the left edge and the last (3:55, or 3:59
    # for 1-minute data) to the right edge.
    ys = {}
    for t, c in pts:
        x = int(math.round((t - q["start"]) * (WIDTH - 1) / (span - q["bar"])))
        x = max(0, min(WIDTH - 1, x))
        ys[x] = y_of(c)
    first, last = min(ys.keys()), max(ys.keys())

    # Line segments per column, joined vertically to the previous column.
    segs = []
    last_y = None
    for x in range(first, last + 1):
        y = ys.get(x, last_y)
        a, b = (y, y) if last_y == None else (min(y, last_y), max(y, last_y))
        segs.append((x, a, b))
        last_y = y

    # Area fill: a gradient that fades toward the bottom, masked off above the line.
    width = last - first + 1
    fill = []
    for r in range(CHART_H):
        k = r / (CHART_H - 1)
        fill.append(box(first, CHART_TOP + r, width, 1, mix("#000000", color, 0.42 - 0.36 * k)))
    mask = [column(x, CHART_TOP, a - CHART_TOP, "#000000") for x, a, _ in segs if a > CHART_TOP]

    # Dotted previous close across the whole chart.
    base = []
    if prev != None:
        py = y_of(prev)
        base = [column(x, py, 1, BASELINE) for x in range(0, WIDTH, 2)]

    line = [column(x, a, b - a + 1, color) for x, a, b in segs]
    return fill + mask + base + line, (last, last_y)

def arrow(x, y, up, color):
    """5x3 triangle, pointing up or down."""
    rows = [(2, 1), (1, 3), (0, 5)]
    return [box(x + dx, y + (i if up else 2 - i), w, 1, color) for i, (dx, w) in enumerate(rows)]

def chip(s, color):
    """Text knocked out of a small rounded tag."""
    w = 4 * len(s) + 2
    return render.Stack(children = [
        render.Box(width = w, height = 7, color = color),
        render.Padding(pad = (1, 1, 0, 0), child = render.Text(s, font = "tom-thumb", color = "#000000")),
    ] + [box(cx, cy, 1, 1, "#000000") for cx in (0, w - 1) for cy in (0, 6)])

def ticker_frames(symbol, label, frames):
    q = quote(symbol)
    head = render.Text(label, font = "tb-8", color = INK)
    if q == None:
        frame = render.Stack(children = [
            head,
            render.Padding(pad = (0, 10, 0, 0), child = render.Text("no data", font = "tom-thumb", color = MUTED)),
            column(0, 31, 1, "#000000"),
        ] + [column(x, CHART_TOP + CHART_H // 2, 1, BASELINE) for x in range(0, WIDTH, 2)])
        return [frame] * frames

    price, prev = q["price"], q["prev"]
    kids = [render.Row(
        expanded = True,
        main_align = "space_between",
        children = [head, render.Text(fmt_price(price), font = "tb-8", color = INK)],
    )]
    if prev:
        chg = price - prev
        pct = chg / prev * 100
        color = UP if chg >= 0 else DOWN
        kids.extend(arrow(0, 10, chg >= 0, color))
        kids.append(render.Padding(pad = (6, 8, 0, 0), child = render.Text(fmt(abs(chg), 2), font = "tom-thumb", color = color)))
        kids.append(render.Padding(pad = (0, 8, 0, 0), child = render.Row(
            expanded = True,
            main_align = "end",
            children = [chip(signed(pct, 2) + "%", color)],
        )))
    else:
        color = FLAT

    layers, dot = chart_layers(q, color)
    still = render.Stack(children = layers + kids)
    if dot == None:
        return [still] * frames

    # The latest price blinks: white with a glow, then back to the line color.
    x, y = dot
    glow = mix(color, "#ffffff", 0.35)
    halo = [box(x + dx, y + dy, 1, 1, glow) for dx, dy in ((-1, 0), (1, 0), (0, -1), (0, 1))
            if 0 <= x + dx and x + dx < WIDTH and CHART_TOP <= y + dy and y + dy < 32]
    lit = render.Stack(children = layers + halo + [box(x, y, 1, 1, "#ffffff")] + kids)
    return [lit if (f // 5) % 2 == 0 else still for f in range(frames)]

def parse_tickers(s):
    out = []
    for item in s.split(","):
        item = item.strip()
        if not item:
            continue
        if ":" in item:
            sym, label = item.split(":", 1)
        else:
            sym, label = item, item.lstrip("^")
        out.append((sym.strip().upper(), label.strip()))
    return out

def main(config):
    tickers = parse_tickers(config.get("tickers", DEFAULT_TICKERS)) or parse_tickers(DEFAULT_TICKERS)
    seconds = int(config.get("seconds", "5"))
    frames = max(10, seconds * 1000 // DELAY_MS)

    all_frames = []
    for sym, label in tickers:
        all_frames.extend(ticker_frames(sym, label, frames))
    return render.Root(delay = DELAY_MS, child = render.Animation(children = all_frames))
