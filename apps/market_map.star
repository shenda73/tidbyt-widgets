"""
Market map for Tidbyt.
A treemap of where the money is trading today. Each tile is one of the most
traded US stocks: its area is the dollar volume traded so far, its color is
the change since the previous close (red to green). Tiles trading at an
unusually high volume for the time of day breathe. Labels switch between the
ticker and the percent change.

Data comes from Yahoo Finance's "most active" screener, which needs no key.

Config (all optional):
  count    number of tiles (default 12)
  scale    percent change that gets the full red or green (default 4)
  unusual  relative volume from which a tile breathes (default 1.5)
"""

load("http.star", "http")
load("math.star", "math")
load("render.star", "render")
load("time.star", "time")

URLS = [
    "https://query1.finance.yahoo.com/v1/finance/screener/predefined/saved?scrIds=most_actives&count=100",
    "https://query2.finance.yahoo.com/v1/finance/screener/predefined/saved?scrIds=most_actives&count=100",
]
HEADERS = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"}

W, H = 64, 32
FONT = "CG-pixel-3x5-mono"  # 3x5 glyphs, 4 px per character
DELAY_MS = 100
WIDE = 1.7  # split side by side only when a tile is at least this wide for its height
PHASE_FRAMES = 30  # frames per label (ticker, then change)
BREATH_FRAMES = 20  # frames per breath of an unusual-volume tile

NEUTRAL = "#262a33"
UP = "#12d65c"
DOWN = "#ff2f45"

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

def fetch():
    for url in URLS:
        resp = http.get(url, headers = HEADERS)
        if resp.status_code != 200:
            continue
        result = resp.json().get("finance", {}).get("result")
        if result and result[0].get("quotes"):
            return result[0]["quotes"]
    return None

def expected_share(quotes):
    """Share of a normal day's volume that should be done by now."""
    if not quotes or quotes[0].get("marketState") != "REGULAR":
        return 1.0  # outside the session the numbers are a full day's
    now = time.now().in_location("America/New_York")
    x = clamp(((now.hour - 9) * 60 + now.minute - 30) / 390, 0.0, 1.0)
    for i in range(1, len(VOLUME_CURVE)):
        x0, y0 = VOLUME_CURVE[i - 1]
        x1, y1 = VOLUME_CURVE[i]
        if x <= x1:
            return max(0.02, y0 + (y1 - y0) * (x - x0) / (x1 - x0))
    return 1.0

def stocks(quotes, count):
    """The `count` stocks with the highest dollar volume, largest first."""
    share = expected_share(quotes)
    out = []
    for q in quotes:
        price, volume = q.get("regularMarketPrice"), q.get("regularMarketVolume")
        if not price or not volume:
            continue
        avg = q.get("averageDailyVolume3Month") or 0
        out.append({
            "symbol": q["symbol"],
            "value": price * volume,
            "pct": q.get("regularMarketChangePercent") or 0.0,
            "rvol": volume / (avg * share) if avg else 1.0,
        })
    return sorted(out, key = lambda s: s["value"], reverse = True)[:count]

def total_value(part):
    total = 0
    for s in part:
        total += s["value"]
    return total

def treemap(items):
    """Lay items out in the screen by halving: split the list into two parts
    of about equal value, split the rectangle to match, and repeat."""
    tiles = []
    stack = [(items, 0, 0, W, H)]
    for _ in range(4 * len(items) + 4):
        if not stack:
            break
        part, x, y, w, h = stack.pop()
        if len(part) == 1 or (w < 2 and h < 2):
            tiles.append((part[0], x, y, w, h))
            continue

        total = total_value(part)
        run, k, best = 0, 1, None
        for i in range(len(part) - 1):
            run += part[i]["value"]
            miss = abs(run - total / 2)
            if best == None or miss < best:
                best, k = miss, i + 1
        first = total_value(part[:k]) / total

        # Labels are wide and short, so prefer tiles that are too.
        if w >= WIDE * h:
            w1 = clamp(int(math.round(w * first)), 1, w - 1)
            stack.append((part[k:], x + w1, y, w - w1, h))
            stack.append((part[:k], x, y, w1, h))
        else:
            h1 = clamp(int(math.round(h * first)), 1, h - 1)
            stack.append((part[k:], x, y + h1, w, h - h1))
            stack.append((part[:k], x, y, w, h1))
    return tiles

def tile_color(pct, scale):
    t = math.pow(clamp(abs(pct) / scale, 0.0, 1.0), 0.7)  # keep small moves visible
    return lerp_color(NEUTRAL, UP if pct >= 0 else DOWN, t)

def pct_text(pct):
    a = abs(pct)
    sign = "+" if pct >= 0 else "-"
    if a >= 9.95:
        return sign + str(int(math.round(a)))
    n = int(math.round(a * 10))
    return "%s%d.%d" % (sign, n // 10, n % 10)

def fits(text, w, h):
    # The text is 4 * len - 1 wide and 5 tall; the tile's own gap keeps it
    # off the next tile.
    return w - 1 >= 4 * len(text) - 1 and h - 1 >= 6

def tile(s, x, y, w, h, color, label):
    # Leave a 1 px gap on the right and bottom as the line between tiles.
    bw, bh = max(1, w - 1), max(1, h - 1)
    if label and fits(label, w, h):
        box = render.Box(width = bw, height = bh, color = color, child = render.Text(label, font = FONT, color = "#ffffff"))
    else:
        box = render.Box(width = bw, height = bh, color = color)
    return render.Padding(pad = (x, y, 0, 0), child = box)

def main(config):
    count = int(config.get("count", "12"))
    scale = float(config.get("scale", "4"))
    unusual = float(config.get("unusual", "1.5"))

    quotes = fetch()
    if quotes == None:
        return render.Root(child = render.Box(child = render.Text("no data", font = "tom-thumb", color = "#f55")))

    tiles = treemap(stocks(quotes, count))

    frames = []
    for i in range(2 * PHASE_FRAMES):
        show_pct = i >= PHASE_FRAMES
        breath = 0.5 - 0.5 * math.cos(2 * math.pi * i / BREATH_FRAMES)
        kids = []
        for s, x, y, w, h in tiles:
            color = tile_color(s["pct"], scale)
            if s["rvol"] >= unusual:
                color = lerp_color(color, "#ffffff", 0.22 * breath)

            # Tall tiles show both lines; the others take turns.
            ticker, change = s["symbol"], pct_text(s["pct"])
            if h >= 14 and fits(ticker, w, h) and fits(change, w, h):
                kids.append(tile(s, x, y, w, h, color, None))
                top = y + (h - 1 - 11) // 2
                for n, text in enumerate([ticker, change]):
                    kids.append(render.Padding(
                        pad = (x + (w - 1 - (4 * len(text) - 1)) // 2, top + 6 * n, 0, 0),
                        child = render.Text(text, font = FONT, color = "#ffffff"),
                    ))
            elif show_pct and fits(change, w, h):
                kids.append(tile(s, x, y, w, h, color, change))
            else:
                kids.append(tile(s, x, y, w, h, color, ticker))
        frames.append(render.Stack(children = kids))

    return render.Root(delay = DELAY_MS, child = render.Animation(children = frames))
