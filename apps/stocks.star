"""
Stock watch for Tidbyt.
Cycles through a list of tickers. Each one shows its price, the change since
the previous close and the volume pace: today's volume so far against the
same point of the day over the past month (1.0x is normal; amber from 1.5x).

Below, the day's price so far is an area chart on the left, and on the right,
on the same price scale, is its volume profile: a sideways histogram of how
much traded at each price. The profile runs from deep blue (little volume) to
bright cyan (a lot); the busiest price (the point of control) is amber, and
prices outside the band that holds 70% of the volume (the value area) are
dimmed. A white tick on the profile marks the latest price, and the gray
dotted line is the previous close.

The line draws in and the profile grows out from the point of control when a
ticker comes on.

Data comes from Yahoo Finance's chart API, which needs no key. When Yahoo's
feed for a stock is stale, the price and the line come from Nasdaq's instead.

Config (all optional):
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
    "https://query1.finance.yahoo.com/v8/finance/chart/{}?range=1mo&interval=5m",
    "https://query2.finance.yahoo.com/v8/finance/chart/{}?range=1mo&interval=5m",
]
HEADERS = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"}
NASDAQ_URL = "https://api.nasdaq.com/api/quote/{}/chart?assetclass=stocks"
NASDAQ_HEADERS = {"User-Agent": HEADERS["User-Agent"], "Accept": "application/json"}
STALE_SECS = 15 * 60

FONT = "tom-thumb"
TOP = 15  # chart rows 15..31, under two rows of text
ROWS = 17
LINE_W = 40  # the price chart spans x 0..39
PROFILE_X = 42  # the profile grows right from here, on the same price rows
PROFILE_W = 22  # longest profile bar
DELAY_MS = 100
DRAW_FRAMES = 16  # the line draws in and the profile grows
GLOW_ROWS = 8  # how far the glow under the price line reaches
VALUE_AREA = 0.7

UP, DOWN, FLAT = "#2fe07a", "#ff4d5e", "#aaaaaa"
POC = "#ffb020"
HEAT = ["#16224a", "#2c66cf", "#62d4ff"]  # profile colors, low to high volume
PACE_HOT = "#ffb020"

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
        resp = http.get(url.format(symbol.replace("^", "%5E")), headers = HEADERS)
        if resp.status_code == 200:
            result = resp.json().get("chart", {}).get("result")
            if result:
                return result[0]
    return None

def days(chart):
    """Bars grouped by trading day, oldest day first. Each bar is
    (timestamp, high, low, close, volume)."""
    stamps = chart.get("timestamp") or []
    q = (chart.get("indicators", {}).get("quote") or [{}])[0]
    highs, lows = q.get("high") or [], q.get("low") or []
    closes, volumes = q.get("close") or [], q.get("volume") or []
    tz = chart["meta"].get("exchangeTimezoneName", "America/New_York")

    out, last_day = [], None
    for i, t in enumerate(stamps):
        if i >= len(closes) or closes[i] == None or highs[i] == None or lows[i] == None:
            continue
        day = time.from_timestamp(int(t)).in_location(tz).format("2006-01-02")
        if day != last_day:
            out.append([])
            last_day = day
        out[-1].append((t, highs[i], lows[i], closes[i], volumes[i] or 0))
    return out

def volume_until(bars, elapsed):
    """Volume of a day's bars up to `elapsed` seconds after its first bar."""
    total = 0
    for t, _, _, _, v in bars:
        if t - bars[0][0] <= elapsed:
            total += v
    return total

def row(price, hi, lo):
    """Chart row of a price: 0 at the day's high, ROWS - 1 at its low."""
    return clamp(int((hi - price) / (hi - lo) * (ROWS - 1) + 0.5), 0, ROWS - 1)

def study(symbol):
    chart = fetch(symbol)
    if chart == None:
        return None
    all_days = days(chart)
    if not all_days or len(all_days[-1]) < 2:
        return None
    today, before = all_days[-1], all_days[:-1]

    meta = chart["meta"]
    price = meta.get("regularMarketPrice") or today[-1][3]
    prev = before[-1][-1][3] if before else meta.get("chartPreviousClose")
    line = [b[3] for b in today]

    # Yahoo's feed sometimes runs an hour or more behind for some stocks
    # (SPCX). If its last trade is stale during the session, take the price
    # and the line from Nasdaq; the profile still uses Yahoo's volume.
    period = meta.get("currentTradingPeriod", {}).get("regular")
    now = time.now().unix
    last_trade = meta.get("regularMarketTime") or 0
    if period and not symbol.startswith("^") and period["start"] < now and min(now, period["end"]) - last_trade > STALE_SECS:
        nq = nasdaq_points(symbol, period["start"], period["end"])
        if nq and nq[-1][0] > last_trade:
            line = [p for _, p in nq]
            price = line[-1]

    # Volume pace: today so far against the same stretch of the earlier days.
    elapsed = today[-1][0] - today[0][0]
    pace = None
    usual = [volume_until(d, elapsed) for d in before]
    usual = [u for u in usual if u > 0]
    if usual:
        mean = 0
        for u in usual:
            mean += u
        pace = volume_until(today, elapsed) / (mean / len(usual))

    # The chart's range is the line's, so the line always fills the height;
    # volume from a bar's stray high or low lands in the top or bottom row.
    hi, lo = max(line), min(line)
    if hi == lo:
        hi, lo = hi + 0.01, lo - 0.01

    # Spread each bar's volume evenly over the rows between its low and high.
    profile = [0.0] * ROWS
    for _, h, l, _, v in today:
        r0, r1 = row(h, hi, lo), row(l, hi, lo)
        for r in range(r0, r1 + 1):
            profile[r] += v / (r1 - r0 + 1)

    # Soften single-bar spikes (the opening and closing auctions) a little.
    smooth = []
    for r in range(ROWS):
        above = profile[r - 1] if r > 0 else profile[r]
        below = profile[r + 1] if r < ROWS - 1 else profile[r]
        smooth.append((above + 2 * profile[r] + below) / 4)

    # The price line: one chart row per column. The day so far always fills
    # the chart's width, so it reads as a chart from the first minutes on.
    cols = {}
    for x in range(LINE_W):
        at = x * (len(line) - 1) / (LINE_W - 1)
        i = min(int(at), len(line) - 2)
        a, b = line[i], line[i + 1]
        cols[x] = row(a + (b - a) * (at - i), hi, lo)

    return {
        "price": price,
        "prev": prev,
        "pace": pace,
        "cols": cols,
        "profile": smooth,
        "prev_row": row(prev, hi, lo) if prev and lo <= prev and prev <= hi else None,
    }

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

def value_rows(profile):
    """The point of control and the rows of the value area around it."""
    poc = 0
    total = 0.0
    for r, v in enumerate(profile):
        total += v
        if v > profile[poc]:
            poc = r

    # Grow outward from the point of control, taking the busier side first.
    inside = {poc: True}
    covered = profile[poc]
    up, down = poc - 1, poc + 1
    for _ in range(ROWS):
        if covered >= VALUE_AREA * total:
            break
        above = profile[up] if up >= 0 else -1
        below = profile[down] if down < ROWS else -1
        if above < 0 and below < 0:
            break
        if above >= below:
            inside[up] = True
            covered += above
            up -= 1
        else:
            inside[down] = True
            covered += below
            down += 1
    return poc, inside

def heat(t):
    if t < 0.5:
        return lerp_color(HEAT[0], HEAT[1], t / 0.5)
    return lerp_color(HEAT[1], HEAT[2], (t - 0.5) / 0.5)

def profile_layer(profile, poc, inside, i):
    """The profile at frame i: bars grow out from the point of control."""
    out = []
    peak = profile[poc]
    if peak <= 0:
        return out
    for r, v in enumerate(profile):
        grow = ease_out((i + 1 - abs(r - poc) * 0.6) / (DRAW_FRAMES - 6))
        n = int(math.round(PROFILE_W * v / peak * grow))
        if n <= 0:
            continue
        if r == poc:
            color = POC
        else:
            color = heat(v / peak)
            if r not in inside:
                color = lerp_color(color, "#000000", 0.5)
        out.append(px(PROFILE_X, TOP + r, color, w = n))
    return out

def chart_layer(s, color, shown):
    """Area chart of the price, up to column `shown`. Returns the widgets
    and the position of the last point drawn."""
    cols = s["cols"]
    xs = [x for x in sorted(cols.keys()) if x < shown]
    if not xs:
        return [], None

    # A glow hangs under the line: brightest right below it, fading to
    # black GLOW_ROWS further down.
    out = []
    for depth in range(1, GLOW_ROWS + 1):
        fill = lerp_color("#000000", color, 0.5 * math.pow(1.0 - (depth - 1) / GLOW_ROWS, 1.5))
        run = None
        for x in xs + [None]:
            y = cols[x] + depth if x != None else None
            same = run != None and y == run[1]
            if run != None and not same:
                if run[1] < ROWS:
                    out.append(px(run[0], TOP + run[1], fill, w = (x if x != None else xs[-1] + 1) - run[0]))
                run = None
            if x != None and run == None:
                run = (x, y)

    # Previous close, dotted, where it falls inside the day's range.
    if s["prev_row"] != None:
        for x in range(0, LINE_W, 3):
            out.append(px(x, TOP + s["prev_row"], "#3a3a3a"))

    # The line itself, joined with vertical runs.
    last = None
    for x in xs:
        y = cols[x]
        y0, y1 = (y, y) if last == None else (min(y, last), max(y, last))
        if last != None and y != last:
            if y > last:
                y0 += 1
            else:
                y1 -= 1
        out.append(px(x, TOP + y0, color, h = y1 - y0 + 1))
        last = y
    return out, (xs[-1], TOP + last)

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

def pct_text(price, prev):
    if not prev:
        return ""
    pct = (price - prev) / prev * 100
    return ("+" if pct >= 0 else "-") + fmt(abs(pct), 2 if abs(pct) < 100 else 0) + "%"

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

def header(label, s, color):
    """Two rows: name and price, then change and volume pace."""
    right = []
    if s["pace"] != None:
        pace_color = PACE_HOT if s["pace"] >= 1.5 else "#8a8a8a"
        right = [
            volume_icon(pace_color),
            render.Box(width = 1, height = 1),
            render.Text(pace_text(s["pace"]), font = FONT, color = pace_color),
        ]
    return render.Column(
        children = [
            render.Row(
                expanded = True,
                main_align = "space_between",
                children = [
                    render.Text(label[:5], font = FONT, color = "#ffffff"),
                    render.Text(fmt_price(s["price"]), font = FONT, color = "#ffffff"),
                ],
            ),
            render.Box(width = 1, height = 1),
            render.Row(
                expanded = True,
                main_align = "space_between",
                children = [
                    render.Text(pct_text(s["price"], s["prev"]), font = FONT, color = color),
                    render.Row(children = right),
                ],
            ),
        ],
    )

def ticker_frames(label, s, n):
    color = FLAT
    if s["prev"]:
        color = UP if s["price"] >= s["prev"] else DOWN
    poc, inside = value_rows(s["profile"])
    head = header(label, s, color)

    full_chart, dot = chart_layer(s, color, LINE_W)
    full_chart = render.Stack(children = full_chart)
    full_profile = render.Stack(children = profile_layer(s["profile"], poc, inside, DRAW_FRAMES))

    frames = []
    for i in range(n):
        if i < DRAW_FRAMES:
            shown = int(ease_out((i + 1) / DRAW_FRAMES) * LINE_W + 0.5)
            chart, tip = chart_layer(s, color, shown)
            kids = [head] + profile_layer(s["profile"], poc, inside, i) + chart
            if tip != None:
                kids.append(px(tip[0], tip[1], "#ffffff"))
        else:
            # The latest price breathes, and a tick marks it on the profile.
            pulse = 0.5 - 0.5 * math.cos(2 * math.pi * (i - DRAW_FRAMES) / 16)
            halo = lerp_color("#000000", "#ffffff", 0.12 + 0.3 * pulse)
            x, y = dot
            kids = [head, full_profile, full_chart]
            for dx, dy in [(-1, 0), (1, 0), (0, -1), (0, 1)]:
                if 0 <= x + dx and x + dx < LINE_W and TOP <= y + dy and y + dy < TOP + ROWS:
                    kids.append(px(x + dx, y + dy, halo))
            kids.append(px(x, y, "#ffffff"))
            kids.append(px(PROFILE_X - 1, y, lerp_color("#555555", "#ffffff", pulse)))
        frames.append(render.Stack(children = kids))
    return frames

def main(config):
    seconds = int(config.get("seconds", "5"))
    n = max(DRAW_FRAMES + 16, seconds * 1000 // DELAY_MS)

    frames = []
    for item in config.get("tickers", DEFAULT_TICKERS).split(","):
        parts = item.strip().split(":")
        symbol = parts[0]
        label = parts[1] if len(parts) > 1 else symbol.replace("^", "")
        s = study(symbol)
        if s != None:
            frames += ticker_frames(label, s, n)

    if not frames:
        return render.Root(child = render.Box(child = render.Text("no data", font = FONT, color = "#f55")))
    return render.Root(delay = DELAY_MS, child = render.Animation(children = frames))
