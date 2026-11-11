"""
Volume profile for Tidbyt.
Cycles through a list of tickers. For each one, the day's price line sits next
to a volume profile: a sideways histogram of how much traded at each price,
on the same price scale as the line.
The busiest price (the point of control) is amber, the prices around it that
hold 70% of the volume (the value area) are bright, and the rest is dim. The
header shows the change since the previous close and the volume pace: today's
volume so far against the same point of the day over the past month (1.0x is
normal).

Data comes from Yahoo Finance's chart API, which needs no key.

Config (all optional):
  tickers  comma-separated Yahoo symbols, each optionally "SYMBOL:Label"
           (default "SPY,NVDA,TSLA")
  seconds  seconds on screen per ticker (default 5)
"""

load("http.star", "http")
load("math.star", "math")
load("render.star", "render")
load("time.star", "time")

DEFAULT_TICKERS = "SPY,NVDA,TSLA"
URLS = [
    "https://query1.finance.yahoo.com/v8/finance/chart/{}?range=1mo&interval=5m",
    "https://query2.finance.yahoo.com/v8/finance/chart/{}?range=1mo&interval=5m",
]
HEADERS = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"}

W = 64
FONT = "tom-thumb"
TOP = 8  # chart rows 8..31
ROWS = 24
LINE_W = 40  # the price line spans x 0..39
PROFILE_X = 42  # the profile grows right from here, on the same price rows
PROFILE_W = 22  # longest profile bar
SESSION_SECS = 390 * 60
DELAY_MS = 100
GROW_FRAMES = 12  # the profile grows in when a ticker comes on
VALUE_AREA = 0.7

UP, DOWN, FLAT = "#2fe07a", "#ff4d5e", "#aaaaaa"
POC = "#ffb020"
IN_VALUE = "#2f5fa8"
OUT_VALUE = "#182c4c"
PACE_HOT = "#ffb020"

def clamp(v, lo, hi):
    return max(lo, min(hi, v))

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

def study(symbol):
    chart = fetch(symbol)
    if chart == None:
        return None
    all_days = days(chart)
    if not all_days or len(all_days[-1]) < 2:
        return None
    today, before = all_days[-1], all_days[:-1]

    price = today[-1][3]
    prev = before[-1][-1][3] if before else chart["meta"].get("chartPreviousClose")

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

    hi = max([b[1] for b in today])
    lo = min([b[2] for b in today])
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
    profile = smooth

    return {
        "price": price,
        "prev": prev,
        "pace": pace,
        "today": today,
        "hi": hi,
        "lo": lo,
        "profile": profile,
    }

def row(price, hi, lo):
    """Chart row of a price: 0 at the day's high, ROWS - 1 at its low."""
    return clamp(int((hi - price) / (hi - lo) * (ROWS - 1) + 0.5), 0, ROWS - 1)

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

def profile_layer(profile, poc, inside, grow):
    """Bars at `grow` (0..1) of their full length."""
    out = []
    peak = profile[poc]
    if peak <= 0:
        return out
    for r, v in enumerate(profile):
        n = int(math.round(PROFILE_W * v / peak * grow))
        if n <= 0:
            continue
        color = POC if r == poc else (IN_VALUE if r in inside else OUT_VALUE)
        out.append(px(PROFILE_X, TOP + r, color, w = n))
    return out

def line_layer(s, color):
    """Price line across the session; x is time since the open."""
    today = s["today"]
    start = today[0][0]
    out = []
    last_y = None
    seen = {}
    for t, _, _, c, _ in today:
        x = clamp(int((t - start) / SESSION_SECS * (LINE_W - 1) + 0.5), 0, LINE_W - 1)
        y = row(c, s["hi"], s["lo"])
        if x in seen:
            continue
        seen[x] = True

        # Join to the previous point with a vertical run.
        y0, y1 = (y, y) if last_y == None else (min(y, last_y), max(y, last_y))
        if last_y != None and y != last_y:
            if y > last_y:
                y0 += 1
            else:
                y1 -= 1
        out.append(px(x, TOP + y0, color, h = y1 - y0 + 1))
        last_y = y
    return out, (x, TOP + y)

def pct_text(price, prev):
    if not prev:
        return ""
    pct = (price - prev) / prev * 100
    a = abs(pct)
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

def header(label, s, color):
    right = []
    if s["pace"] != None:
        pace_color = PACE_HOT if s["pace"] >= 1.5 else "#8a8a8a"
        right = [
            volume_icon(pace_color),
            render.Box(width = 1, height = 1),
            render.Text(pace_text(s["pace"]), font = FONT, color = pace_color),
        ]
    return render.Row(
        expanded = True,
        main_align = "space_between",
        children = [
            render.Text(label[:4], font = FONT, color = "#ffffff"),
            render.Text(pct_text(s["price"], s["prev"]), font = FONT, color = color),
            render.Row(children = right),
        ],
    )

def ticker_frames(label, s, n):
    color = FLAT
    if s["prev"]:
        color = UP if s["price"] >= s["prev"] else DOWN
    poc, inside = value_rows(s["profile"])
    line, (dot_x, dot_y) = line_layer(s, color)
    head = header(label, s, color)
    full = profile_layer(s["profile"], poc, inside, 1.0)

    frames = []
    for i in range(n):
        if i < GROW_FRAMES:
            ease = 1.0 - math.pow(1.0 - (i + 1) / GROW_FRAMES, 2)
            bars = profile_layer(s["profile"], poc, inside, ease)
        else:
            bars = full

        # The latest price blinks.
        dot = [px(dot_x, dot_y, "#ffffff")] if (i // 5) % 2 == 0 else []
        frames.append(render.Stack(children = [head] + bars + line + dot))
    return frames

def main(config):
    seconds = int(config.get("seconds", "5"))
    n = max(GROW_FRAMES + 10, seconds * 1000 // DELAY_MS)

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
