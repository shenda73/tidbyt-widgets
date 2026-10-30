"""
Applet: Flights Overhead
Summary: Spotter card for the planes and helicopters near you
Description: Cycles through the nearest aircraft. Each gets a card with its
callsign, aircraft type, altitude, and distance and direction from you, above
a little sky where its sprite flies past in the direction it's heading, at a
height that follows its altitude. Helicopters are amber, with a spinning rotor.
Data: airplanes.live (fallback adsb.lol), both free, no key.

Config (all optional):
  lat, lng    your location (default: JFK Airport)
  radius_nm   search radius in nautical miles (default: 3)
  seconds     seconds on screen per aircraft (default 5)
"""

load("http.star", "http")
load("math.star", "math")
load("render.star", "render")

DEFAULT_LAT = "40.6413"
DEFAULT_LNG = "-73.7781"
DEFAULT_RADIUS_NM = "3"
MAX_SHOWN = 3
DELAY_MS = 100

SOURCES = [
    "https://api.airplanes.live/v2/point/%s/%s/%s",
    "https://api.adsb.lol/v2/point/%s/%s/%s",
]

W = 64
SKY_TOP = 16  # the scene is rows 16..31
FONT = "tom-thumb"
INK, MUTED = "#f4f4f4", "#8a94a6"
PLANE, HELI = "#7fd8ff", "#ffb347"
HEX = "0123456789abcdef"
DEG = math.pi / 180

# Sprites facing right. "b" body, "a" accent (tail/rotor), "w" window, "e" engine.
JET = [
    "a..........",
    "aa.........",
    "bbbbbbbbwb.",
    ".bbbbbbbbbb",
    "....ee.....",
]
CHOPPER = [
    "aaaaaaaaa",
    "....b....",
    "b..bbbb..",
    "bbbbbbwb.",
    "...bbbb..",
    "...b..b..",
]

# Low skyline along the bottom of the scene: (x, width, height).
CITY = [(0, 5, 2), (5, 3, 4), (8, 6, 2), (15, 2, 5), (17, 5, 3), (24, 4, 2),
        (29, 3, 4), (33, 6, 2), (40, 2, 6), (42, 4, 3), (48, 5, 2), (54, 3, 4), (58, 6, 2)]

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

def fetch(lat, lng, radius):
    for src in SOURCES:
        resp = http.get(src % (lat, lng, radius))  # Pixlet 0.34 has no ttl_seconds
        if resp.status_code == 200:
            return resp.json().get("ac") or []
    return None

def compass(bearing):
    names = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
    return names[int((bearing + 22.5) // 45) % 8]

def one_decimal(v):
    d = int(v * 10 + 0.5)
    return "%d.%d" % (d // 10, d % 10)

def thousands(n):
    s = str(n)
    return s if len(s) <= 3 else s[:-3] + "," + s[-3:]

def parse(ac, flat, flng):
    coslat = math.cos(flat * DEG)
    craft = []
    for a in ac:
        alt = a.get("alt_baro")
        if alt == None or type(alt) == "string":  # "ground" or missing
            continue
        if a.get("lat") == None or a.get("lon") == None:
            continue
        east = (a["lon"] - flng) * coslat * 69.0
        north = (a["lat"] - flat) * 69.0
        bearing = math.atan2(east, north) / DEG
        name = (a.get("flight") or "").strip() or a.get("r") or a.get("hex", "").upper()
        craft.append({
            "name": name[:7],
            "type": (a.get("t") or "")[:4],
            "alt": int(alt),
            "heli": a.get("category") == "A7",
            "dist": math.sqrt(east * east + north * north),
            "bearing": bearing + 360 if bearing < 0 else bearing,
            "track": a.get("track"),
        })
    return sorted(craft, key = lambda c: c["dist"])

def chip(s, color):
    """Text knocked out of a small rounded tag."""
    w = 4 * len(s) + 2
    return render.Stack(children = [
        render.Box(width = w, height = 7, color = color),
        render.Padding(pad = (1, 1, 0, 0), child = render.Text(s, font = FONT, color = "#000000")),
    ] + [box(cx, cy, 1, 1, "#000000") for cx in (0, w - 1) for cy in (0, 6)])

def scene_background():
    kids = []
    for y in range(SKY_TOP, 32):
        kids.append(box(0, y, W, 1, mix("#04070f", "#132449", (y - SKY_TOP) / 15.0)))
    for sx, sy in ((6, 18), (21, 17), (37, 19), (52, 17), (60, 21), (29, 22)):
        kids.append(box(sx, sy, 1, 1, "#33416a"))
    kids += [box(x, 32 - h, w, h, "#070b16") for x, w, h in CITY]
    return kids

def sprite(rows, x, y, flip, colors):
    kids = []
    for dy, r in enumerate(rows):
        n = len(r)
        for dx, ch in enumerate(r.elems()):
            if ch == ".":
                continue
            px = x + (n - 1 - dx if flip else dx)
            if 0 <= px and px < W:
                kids.append(box(px, y + dy, 1, 1, colors[ch]))
    return kids

def flyby(c, f, frames):
    """The aircraft crossing the scene at frame f."""
    heading_east = c["track"] == None or math.sin(c["track"] * DEG) >= 0
    rows = CHOPPER if c["heli"] else JET
    n = len(rows[0])
    accent = HELI if c["heli"] else PLANE

    # Higher aircraft fly higher in the scene.
    top = SKY_TOP + 1 + int((1 - min(c["alt"], 30000) / 30000.0) * 7)

    # Cross the whole scene once per card.
    travel = W + n + 12
    p = f * travel // frames - n
    x = p if heading_east else W - 1 - p - (n - 1)

    kids = []
    if not c["heli"]:
        # A fading contrail behind the jet.
        tail_y = top + 2
        for k in range(1, 16):
            tx = x - k if heading_east else x + n - 1 + k
            if 0 <= tx and tx < W and k % 2 == 1:
                kids.append(box(tx, tail_y, 1, 1, mix("#000000", "#9fb4d8", 0.7 - k * 0.04)))

    colors = {
        "a": accent if (not c["heli"] or f % 2 == 0) else mix(accent, "#000000", 0.6),
        "b": "#dfe7f0" if not c["heli"] else HELI,
        "w": "#1d3a5c" if not c["heli"] else "#bff0ff",
        "e": "#6b7686",
    }
    kids += sprite(rows, x, top, not heading_east, colors)

    # Nav strobe on the nose-side tip.
    if f % 10 < 2:
        sx = x + n - 1 if heading_east else x
        if 0 <= sx and sx < W:
            kids.append(box(sx, top + (3 if not c["heli"] else 2), 1, 1, "#ff3b3b" if heading_east else "#3bff6b"))
    return kids

def card(c, idx, total, frames, background):
    accent = HELI if c["heli"] else PLANE
    alt = c["alt"]
    alt_txt = ("FL%d" % (alt // 100)) if alt >= 18000 else thousands(alt) + "FT"
    head = [
        render.Row(
            expanded = True,
            main_align = "space_between",
            children = [render.Text(c["name"], font = "tb-8", color = INK)] +
                       ([chip(c["type"], accent)] if c["type"] else []),
        ),
        render.Padding(pad = (0, 8, 0, 0), child = render.Row(
            expanded = True,
            main_align = "space_between",
            children = [
                render.Text(alt_txt, font = FONT, color = accent),
                render.Text(one_decimal(c["dist"]) + "MI " + compass(c["bearing"]), font = FONT, color = MUTED),
            ],
        )),
    ]

    # Page dots, bottom right, when there's more than one aircraft.
    dots = []
    if total > 1:
        for k in range(total):
            dots.append(box(W - 2 - 3 * (total - 1 - k), 30, 2, 1, accent if k == idx else "#2a3550"))

    return [
        render.Stack(children = background + flyby(c, f, frames) + dots + head)
        for f in range(frames)
    ]

def clear_skies(background):
    return render.Stack(children = background + [
        render.Padding(pad = (0, 1, 0, 0), child = render.Text("CLEAR", font = "tb-8", color = INK)),
        render.Padding(pad = (0, 9, 0, 0), child = render.Text("nothing overhead", font = FONT, color = MUTED)),
    ])

def main(config):
    lat = config.get("lat", DEFAULT_LAT)
    lng = config.get("lng", DEFAULT_LNG)
    frames = max(10, int(config.get("seconds", "5")) * 1000 // DELAY_MS)

    ac = fetch(lat, lng, config.get("radius_nm", DEFAULT_RADIUS_NM))
    if ac == None:
        return render.Root(child = render.Box(child = render.Text("ADS-B down", font = FONT, color = "#f55")))

    shown = parse(ac, float(lat), float(lng))[:MAX_SHOWN]
    background = scene_background()
    if not shown:
        return render.Root(child = clear_skies(background))

    all_frames = []
    for i, c in enumerate(shown):
        all_frames.extend(card(c, i, len(shown), frames, background))
    return render.Root(delay = DELAY_MS, child = render.Animation(children = all_frames))
