"""
Market map for Tidbyt.
A treemap of where the money is trading today. Each tile is one of the most
traded US stocks: its area is the dollar volume traded so far, its color is
the change since the previous close (red to green, brighter for bigger
moves). A glint of light crosses the tiles that are trading at an unusually
high volume for the time of day. Labels fade between the ticker and the
percent change.

The tiles grow into place when the widget comes on.

Data comes from Yahoo Finance's "most active" screener, which needs no key.

Config (all optional):
  count    number of tiles (default 12)
  scale    percent change that gets the full red or green (default 4)
  unusual  relative volume from which a tile glints (default 1.5)
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
FONT = "tom-thumb"  # 3x5 glyphs, 4 px per character
DELAY_MS = 100
FRAMES = 150  # one 15 s loop: about one turn in the rotation
INTRO = 16  # frames for the tiles to grow into place
LABEL_HOLD = 34  # frames a label stays before fading to the other
LABEL_FADE = 6
GLINT_EVERY = 50  # frames between glints
GLINT_FRAMES = 14  # frames a glint takes to cross a tile
STRETCH = 1.8  # aim for tiles this much wider than tall, to fit labels

NEUTRAL = "#20232b"
UP_LOW, UP = "#0f4a2a", "#1ee67a"
DOWN_LOW, DOWN = "#5a1620", "#ff3b4e"

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

    # Judge volume against the other active stocks too: early in the day
    # almost everything runs ahead of the usual curve.
    ranked = sorted([s["rvol"] for s in out])
    typical = max(1.0, ranked[len(ranked) // 2]) if ranked else 1.0
    for s in out:
        s["rvol"] = s["rvol"] / typical
    return sorted(out, key = lambda s: s["value"], reverse = True)[:count]

def worst(areas, side):
    """Worst aspect ratio of a row of tiles laid along a side."""
    total, big, small = 0.0, areas[0], areas[0]
    for a in areas:
        total += a
        big, small = max(big, a), min(small, a)
    return max(side * side * big / (total * total), total * total / (side * side * small))

def treemap(items):
    """Squarified treemap: rows of tiles are added along the shorter side
    for as long as that keeps them close to square. The layout is worked out
    on a narrowed screen and stretched back, so tiles come out wide."""
    w, h = W / STRETCH, H * 1.0
    total = 0.0
    for s in items:
        total += s["value"]
    areas = [s["value"] / total * w * h for s in items]

    rects = []  # (item, x, y, w, h) in the narrowed space
    x, y = 0.0, 0.0
    row = []  # indexes of the items in the row being built
    i = 0
    for _ in range(3 * len(items) + 3):
        if i >= len(items) and not row:
            break
        side = min(w, h)
        fits_row = False
        if i < len(items):
            now = [areas[j] for j in row]
            fits_row = not row or worst(now + [areas[i]], side) <= worst(now, side)
        if fits_row:
            row.append(i)
            i += 1
            continue

        # Lay the row out and take its strip off the free space.
        strip = 0.0
        for j in row:
            strip += areas[j]
        if w >= h:
            rw, ty = strip / h, y
            for j in row:
                th = areas[j] / rw
                rects.append((items[j], x, ty, rw, th))
                ty += th
            x, w = x + rw, w - rw
        else:
            rh, tx = strip / w, x
            for j in row:
                tw = areas[j] / rh
                rects.append((items[j], tx, y, tw, rh))
                tx += tw
            y, h = y + rh, h - rh
        row = []

    # Stretch back and snap edges to whole pixels.
    tiles = []
    for s, fx, fy, fw, fh in rects:
        x0, x1 = int(fx * STRETCH + 0.5), int((fx + fw) * STRETCH + 0.5)
        y0, y1 = int(fy + 0.5), int(fy + fh + 0.5)
        if x1 > x0 and y1 > y0:
            tiles.append((s, x0, y0, min(W, x1) - x0, min(H, y1) - y0))
    return tiles

def tile_color(pct, scale):
    if abs(pct) < 0.05:
        return NEUTRAL
    t = math.pow(clamp(abs(pct) / scale, 0.0, 1.0), 0.8)
    return lerp_color(UP_LOW, UP, t) if pct > 0 else lerp_color(DOWN_LOW, DOWN, t)

def shade(color, r, rows):
    """Tiles are lit from above: a little lighter at the top, darker below."""
    t = r / max(1, rows - 1)
    if t < 0.25:
        return lerp_color(color, "#ffffff", 0.14 * (1 - t / 0.25))
    return lerp_color(color, "#000000", 0.42 * (t - 0.25) / 0.75)

def tile_body(x, y, w, h, color, grow):
    """A tile at `grow` (0..1) of its size, growing from its center. The
    last column and row are left dark as the line between tiles."""
    bw, bh = max(1, w - 1), max(1, h - 1)
    gw, gh = max(1, int(bw * grow + 0.5)), max(1, int(bh * grow + 0.5))
    gx, gy = x + (bw - gw) // 2, y + (bh - gh) // 2
    return [px(gx, gy + r, shade(color, r, gh), w = gw) for r in range(gh)]

def glint(x, y, w, h, color, p):
    """A slanted band of light at position p (0..1) across a tile."""
    bw, bh = max(1, w - 1), max(1, h - 1)
    head = int(p * (bw + bh + 3)) - 2
    out = []
    for r in range(bh):
        x0, x1 = max(0, head - r), min(bw, head - r + 2)
        if x1 > x0:
            out.append(px(x + x0, y + r, lerp_color(shade(color, r, bh), "#ffffff", 0.55), w = x1 - x0))
    return out

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

def label(text, x, y, w, h, line, lines, color, alpha):
    """Text centered in a tile, on `line` of `lines`, faded by alpha."""
    if alpha <= 0.02:
        return []
    block = 5 * lines + (lines - 1)
    tx = x + (w - 1 - (4 * len(text) - 1)) // 2
    ty = y + (h - 1 - block) // 2 + 6 * line
    return [render.Padding(
        pad = (tx, ty, 0, 0),
        child = render.Text(text, font = FONT, color = lerp_color(color, "#ffffff", alpha)),
    )]

def label_mix(i):
    """(ticker alpha, change alpha) at frame i: fade in after the intro,
    then trade places every LABEL_HOLD frames."""
    if i < INTRO:
        return 0.0, 0.0
    k = i - INTRO
    if k < LABEL_FADE:
        return k / LABEL_FADE, 0.0
    period = LABEL_HOLD + LABEL_FADE
    phase, pos = (k // period) % 2, k % period
    fade = clamp((pos - LABEL_HOLD) / LABEL_FADE, 0.0, 1.0)  # 0 while held
    return (1.0 - fade, fade) if phase == 0 else (fade, 1.0 - fade)

def main(config):
    count = int(config.get("count", "12"))
    scale = float(config.get("scale", "4"))
    unusual = float(config.get("unusual", "1.5"))

    quotes = fetch()
    if quotes == None:
        return render.Root(child = render.Box(child = render.Text("no data", font = "tom-thumb", color = "#f55")))

    tiles = treemap(stocks(quotes, count))
    colors = [tile_color(s["pct"], scale) for s, _, _, _, _ in tiles]

    # The settled tiles are the same in every frame after the intro.
    settled = []
    for n, (_, x, y, w, h) in enumerate(tiles):
        settled += tile_body(x, y, w, h, colors[n], 1.0)
    settled = render.Stack(children = settled)

    frames = []
    for i in range(FRAMES):
        kids = []
        if i < INTRO:
            # Tiles grow from their centers, the largest first.
            for n, (_, x, y, w, h) in enumerate(tiles):
                start = n * (INTRO - 8) / max(1, len(tiles) - 1)
                grow = ease_out((i + 1 - start) / 8)
                if grow > 0:
                    kids += tile_body(x, y, w, h, colors[n], grow)
        else:
            kids.append(settled)

        a_ticker, a_change = label_mix(i)
        for n, (s, x, y, w, h) in enumerate(tiles):
            # The glints start a little later the further right a tile is,
            # so the light seems to pass across the screen.
            g = (i - INTRO - x // 6) % GLINT_EVERY
            if i >= INTRO + x // 6 and s["rvol"] >= unusual and g < GLINT_FRAMES:
                kids += glint(x, y, w, h, colors[n], g / (GLINT_FRAMES - 1))

            # Tall tiles show both lines; the others fade between them.
            ticker, change = s["symbol"], pct_text(s["pct"])
            shown = max(a_ticker, a_change)
            if h >= 14 and fits(ticker, w, h) and fits(change, w, h):
                kids += label(ticker, x, y, w, h, 0, 2, colors[n], shown)
                kids += label(change, x, y, w, h, 1, 2, colors[n], shown)
            elif fits(ticker, w, h) and fits(change, w, h):
                kids += label(ticker, x, y, w, h, 0, 1, colors[n], a_ticker)
                kids += label(change, x, y, w, h, 0, 1, colors[n], a_change)
            elif fits(ticker, w, h):
                kids += label(ticker, x, y, w, h, 0, 1, colors[n], shown)
        frames.append(render.Stack(children = kids))

    return render.Root(delay = DELAY_MS, child = render.Animation(children = frames))
