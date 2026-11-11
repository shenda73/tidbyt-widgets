"""
Movers for Tidbyt.
The day's biggest moves among US stocks worth over $2 billion: one page for
the top three gainers, one for the top three losers. Each row has the ticker,
the day's price line drawn from the previous close (the dotted line), and the
percent change. A gap at the open shows as a line that starts away from the
dotted line; a slow grind shows as a slope. A bright bar on the right edge of
a row means the stock is trading at twice its usual volume for the time of day
or more.

Data comes from Yahoo Finance's screeners and spark API, which need no key.

Config (all optional):
  seconds  seconds on screen per page (default 6)
"""

load("http.star", "http")
load("math.star", "math")
load("render.star", "render")
load("time.star", "time")

HOSTS = ["https://query1.finance.yahoo.com", "https://query2.finance.yahoo.com"]
SCREENER = "/v1/finance/screener/predefined/saved?scrIds={}&count=10"
SPARK = "/v8/finance/spark?symbols={}&range=1d&interval=5m"
HEADERS = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"}

W = 64
FONT = "tom-thumb"
PER_PAGE = 3
ROW_H = 10  # three rows with a 1 px line between them
CHART_X, CHART_W = 21, 22  # chart spans x 21..42
CHART_H = 8
BARS = 78  # 5-minute bars in a full session
DELAY_MS = 100
DRAW_FRAMES = 14  # the lines draw in from the left
HOT_VOLUME = 2.0

UP, UP_DIM = "#2fe07a", "#14522e"
DOWN, DOWN_DIM = "#ff4d5e", "#5a1a22"
RULE = "#1c1c1c"
HOT = "#ffb020"

# Share of a day's volume usually done by each point of the session: trading
# is heaviest at the open and the close. (session fraction, volume fraction)
VOLUME_CURVE = [(0.0, 0.0), (0.08, 0.15), (0.25, 0.33), (0.5, 0.52), (0.75, 0.70), (0.92, 0.85), (1.0, 1.0)]

def clamp(v, lo, hi):
    return max(lo, min(hi, v))

def px(x, y, color, w = 1, h = 1):
    return render.Padding(
        pad = (x, y, 0, 0),
        child = render.Box(width = w, height = h, color = color),
    )

def get(path):
    for host in HOSTS:
        resp = http.get(host + path, headers = HEADERS)
        if resp.status_code == 200:
            return resp.json()
    return None

def expected_share(state):
    """Share of a normal day's volume that should be done by now."""
    if state != "REGULAR":
        return 1.0  # outside the session the numbers are a full day's
    now = time.now().in_location("America/New_York")
    x = clamp(((now.hour - 9) * 60 + now.minute - 30) / 390, 0.0, 1.0)
    for i in range(1, len(VOLUME_CURVE)):
        x0, y0 = VOLUME_CURVE[i - 1]
        x1, y1 = VOLUME_CURVE[i]
        if x <= x1:
            return max(0.02, y0 + (y1 - y0) * (x - x0) / (x1 - x0))
    return 1.0

def screen(name):
    data = get(SCREENER.format(name))
    if data == None:
        return []
    result = data.get("finance", {}).get("result") or [{}]
    out = []
    for q in result[0].get("quotes") or []:
        pct = q.get("regularMarketChangePercent")
        if pct == None or not q.get("symbol"):
            continue
        usual = (q.get("averageDailyVolume3Month") or 0) * expected_share(q.get("marketState"))
        out.append({
            "symbol": q["symbol"],
            "pct": pct,
            "rvol": (q.get("regularMarketVolume") or 0) / usual if usual else 0,
        })
    return out

def sparks(symbols):
    """Price lines for the symbols: {symbol: (previous close, [closes])}."""
    data = get(SPARK.format(",".join(symbols))) or {}
    out = {}
    for sym, v in data.items():
        closes = [c for c in v.get("close") or [] if c != None]
        prev = v.get("chartPreviousClose") or v.get("previousClose")
        if prev and closes:
            out[sym] = (prev, closes)
    return out

def pct_text(pct):
    a = abs(pct)
    sign = "+" if pct >= 0 else "-"
    if a >= 9.95:
        return "%s%d%%" % (sign, int(math.round(a)))
    n = int(math.round(a * 10))
    return "%s%d.%d%%" % (sign, n // 10, n % 10)

def chart(y0, prev, closes, color, dim, shown):
    """Price line in the row starting at y0, up to `shown` (0..1) of it."""
    lo, hi = min(closes + [prev]), max(closes + [prev])
    if hi == lo:
        hi += 0.01

    def row(p):
        return y0 + 1 + clamp(int((hi - p) / (hi - lo) * (CHART_H - 1) + 0.5), 0, CHART_H - 1)

    out = []

    # Previous close, dotted.
    base = row(prev)
    for x in range(CHART_X, CHART_X + CHART_W, 2):
        out.append(px(x, base, dim))

    # The gap at the open: a dim stem from the previous close to the first
    # price, so the move shows even when the day has barely started.
    first = row(closes[0])
    if first != base:
        out.append(px(CHART_X, min(first, base), dim, h = abs(first - base) + 1))

    # The session fills the chart's width, so a line that stops short means
    # the day is not over.
    last_y = None
    cols = {}
    for i, c in enumerate(closes):
        cols[clamp(i * (CHART_W - 1) // (BARS - 1), 0, CHART_W - 1)] = c
    limit = int(shown * CHART_W + 0.5)
    for col in sorted(cols.keys()):
        if col >= limit:
            break
        y = row(cols[col])
        ya, yb = (y, y) if last_y == None else (min(y, last_y), max(y, last_y))
        if last_y != None and y != last_y:
            if y > last_y:
                ya += 1
            else:
                yb -= 1
        out.append(px(CHART_X + col, ya, color, h = yb - ya + 1))
        last_y = y
    return out

def page(rows, lines, n):
    frames = []
    for i in range(n):
        shown = min(1.0, (i + 1) / DRAW_FRAMES)
        kids = []
        for r, s in enumerate(rows):
            y0 = r * (ROW_H + 1)
            up = s["pct"] >= 0
            color, dim = (UP, UP_DIM) if up else (DOWN, DOWN_DIM)
            if r > 0:
                kids.append(px(0, y0 - 1, RULE, w = W))
            kids.append(render.Padding(
                pad = (0, y0 + 2, 0, 0),
                child = render.Text(s["symbol"][:5], font = FONT, color = "#ffffff"),
            ))
            if s["symbol"] in lines:
                prev, closes = lines[s["symbol"]]
                kids += chart(y0, prev, closes, color, dim, shown)

            # Percent change, right-aligned, leaving the last column free.
            text = pct_text(s["pct"])
            kids.append(render.Padding(
                pad = (W - 2 - 4 * len(text), y0 + 2, 0, 0),
                child = render.Text(text, font = FONT, color = color),
            ))
            if s["rvol"] >= HOT_VOLUME:
                kids.append(px(W - 1, y0 + 1, HOT, h = ROW_H - 2))
        frames.append(render.Stack(children = kids))
    return frames

def main(config):
    seconds = int(config.get("seconds", "6"))
    n = max(DRAW_FRAMES + 10, seconds * 1000 // DELAY_MS)

    gainers = sorted(screen("day_gainers"), key = lambda s: s["pct"], reverse = True)[:PER_PAGE]
    losers = sorted(screen("day_losers"), key = lambda s: s["pct"])[:PER_PAGE]
    if not gainers and not losers:
        return render.Root(child = render.Box(child = render.Text("no data", font = FONT, color = "#f55")))

    lines = sparks([s["symbol"] for s in gainers + losers])
    frames = []
    for rows in [gainers, losers]:
        if rows:
            frames += page(rows, lines, n)
    return render.Root(delay = DELAY_MS, child = render.Animation(children = frames))
