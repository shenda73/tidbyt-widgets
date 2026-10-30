"""
Applet: Flights Overhead
Summary: Radar scope of planes and helicopters near you
Description: Animated radar sweep (left) with live ADS-B blips, an optional river line,
and a target-locked info panel (right) cycling the nearest aircraft. Helicopters in orange.
Data: airplanes.live (fallback adsb.lol), both free, no key.

Config (all optional):
  lat, lng          center of the scope (default: JFK Airport)
  radius_nm         scope radius in nautical miles (default: 3)
  river_offset_mi   draw a straight river line this many miles east of center
                    (negative = west); omit for no river
  river_bearing     the river's direction in degrees east of north (default: 0)
"""

load("http.star", "http")
load("math.star", "math")
load("render.star", "render")

DEFAULT_LAT = "40.6413"
DEFAULT_LNG = "-73.7781"
DEFAULT_RADIUS_NM = "3"
MAX_SHOWN = 5

SOURCES = [
    "https://api.airplanes.live/v2/point/%s/%s/%s",
    "https://api.adsb.lol/v2/point/%s/%s/%s",
]

# Radar geometry: 32x32 scope on the left half.
CX = 15
CY = 15
R = 15
STEPS = 24  # sweep positions per rotation (15 degrees each)
ROTATIONS_PER_TARGET = 2
DELAY_MS = 60

RING = "#0b3d0b"
RING_INNER = "#072707"
RIVER = "#0a2a55"
SWEEP = ["#5dff5d", "#1f8f1f", "#0e4d0e"]  # head, trail 1, trail 2
PLANE = ["#7fe8ff", "#1d6f86"]  # bright, dim
HELI = ["#ffb347", "#8a5410"]
LOCK = "#ffffff"
TEXT_DIM = "#5a7a5a"
TEXT = "#d0d0d0"

DEG = math.pi / 180

def px(x, y, color):
    return render.Padding(pad = (x, y, 0, 0), child = render.Box(width = 1, height = 1, color = color))

def in_scope(x, y):
    return x >= 0 and x < 32 and y >= 0 and y < 32 and (x - CX) * (x - CX) + (y - CY) * (y - CY) <= R * R

def ring_points(radius, dotted):
    seen = {}
    for a in range(0, 360, 3):
        x = int(math.round(CX + radius * math.sin(a * DEG)))
        y = int(math.round(CY - radius * math.cos(a * DEG)))
        if dotted and (a // 3) % 2 == 1:
            continue
        seen[(x, y)] = True
    return seen.keys()

def line_points(angle_deg):
    pts = []
    for r in range(1, R + 1):
        x = int(math.round(CX + r * math.sin(angle_deg * DEG)))
        y = int(math.round(CY - r * math.cos(angle_deg * DEG)))
        pts.append((x, y))
    return pts

def static_layer(scale_px_per_mi, river_offset_mi, river_bearing):
    kids = []

    # Optional river: a straight line offset east (or west) of center.
    if river_offset_mi != None:
        off = river_offset_mi * scale_px_per_mi
        dx = math.sin(river_bearing * DEG)
        dy = -math.cos(river_bearing * DEG)
        for t in range(-R * 2, R * 2 + 1):
            x = int(math.round(CX + off + t * dx * 0.5))
            y = int(math.round(CY + t * dy * 0.5))
            if in_scope(x, y):
                kids.append(px(x, y, RIVER))

    for (x, y) in ring_points(R, False):
        kids.append(px(x, y, RING))
    for (x, y) in ring_points(R // 2, True):
        kids.append(px(x, y, RING_INNER))

    # Crosshair ticks at N/E/S/W.
    for (x, y) in [(CX, CY - R + 1), (CX + R - 1, CY), (CX, CY + R - 1), (CX - R + 1, CY)]:
        kids.append(px(x, y, RING))
    return kids

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

def parse(ac, flat, flng, scale):
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
        dist = math.sqrt(east * east + north * north)
        bearing = math.atan2(east, north) / DEG
        if bearing < 0:
            bearing += 360
        name = (a.get("flight") or "").strip() or a.get("r") or a.get("hex", "").upper()
        x = int(math.round(CX + east * scale))
        y = int(math.round(CY - north * scale))
        track = a.get("track")
        tail = None
        if track != None:
            tx = int(math.round(x - math.sin(track * DEG) * 2))
            ty = int(math.round(y + math.cos(track * DEG) * 2))
            tail = (tx, ty)
        craft.append({
            "name": name[:8],
            "type": a.get("t") or "",
            "alt": int(alt),
            "heli": a.get("category") == "A7",
            "dist": dist,
            "bearing": bearing,
            "x": x,
            "y": y,
            "tail": tail,
        })
    return sorted(craft, key = lambda c: c["dist"])

def blip_layer(craft, sweep_angle, locked):
    kids = []
    for i, c in enumerate(craft):
        if not in_scope(c["x"], c["y"]):
            continue
        colors = HELI if c["heli"] else PLANE

        # Bright right after the sweep passes, then fades like a phosphor scope.
        since = (sweep_angle - c["bearing"]) % 360
        color = colors[0] if since < 90 else colors[1]

        if c["tail"] and in_scope(c["tail"][0], c["tail"][1]):
            kids.append(px(c["tail"][0], c["tail"][1], colors[1]))
        kids.append(px(c["x"], c["y"], color))

        if i == locked:
            # Corner brackets around the locked target.
            for (ox, oy) in [(-2, -2), (2, -2), (-2, 2), (2, 2)]:
                bx = c["x"] + ox
                by = c["y"] + oy
                if bx >= 0 and bx < 32 and by >= 0 and by < 32:
                    kids.append(px(bx, by, LOCK))
    return kids

def sweep_layer(lines, step):
    kids = []
    for k in range(len(SWEEP) - 1, -1, -1):
        for (x, y) in lines[(step - k) % STEPS]:
            kids.append(px(x, y, SWEEP[k]))
    return kids

def panel(c, total, blink):
    if c == None:
        return render.Column(
            expanded = True,
            main_align = "center",
            cross_align = "center",
            children = [
                render.Text("CLEAR", font = "tom-thumb", color = TEXT_DIM),
                render.Text("SKIES", font = "tom-thumb", color = TEXT_DIM),
            ],
        )
    color = HELI[0] if c["heli"] else PLANE[0]
    alt = c["alt"]
    alt_txt = ("FL%d" % (alt // 100)) if alt >= 18000 else ("%dft" % alt)
    kind = "HELI" if c["heli"] else "JET"
    return render.Column(
        expanded = True,
        main_align = "space_between",
        children = [
            render.Row(
                expanded = True,
                main_align = "space_between",
                children = [
                    render.Text("%d TGT" % total, font = "tom-thumb", color = TEXT_DIM),
                    render.Box(width = 2, height = 2, color = color if blink else "#000"),
                ],
            ),
            render.Text(c["name"], font = "tom-thumb", color = color),
            render.Text(c["type"] or kind, font = "tom-thumb", color = TEXT),
            render.Text(alt_txt, font = "tom-thumb", color = TEXT),
            render.Text("%s%s" % (one_decimal(c["dist"]), compass(c["bearing"])), font = "tom-thumb", color = TEXT),
        ],
    )

def main(config):
    lat = config.get("lat", DEFAULT_LAT)
    lng = config.get("lng", DEFAULT_LNG)
    radius_nm = float(config.get("radius_nm", DEFAULT_RADIUS_NM))
    radius_mi = radius_nm * 1.15078
    scale = R / radius_mi

    ac = fetch(lat, lng, config.get("radius_nm", DEFAULT_RADIUS_NM))
    if ac == None:
        return render.Root(child = render.Box(child = render.Text("ADS-B down", font = "tom-thumb", color = "#f55")))

    craft = parse(ac, float(lat), float(lng), scale)
    shown = craft[:MAX_SHOWN]

    river_offset = config.get("river_offset_mi")
    static = static_layer(
        scale,
        float(river_offset) if river_offset else None,
        float(config.get("river_bearing", "0")),
    )
    home = [px(CX, CY, "#ffffff")]
    lines = [line_points(s * 360 / STEPS) for s in range(STEPS)]

    targets = range(len(shown)) if shown else [None]
    frames = []
    for t in targets:
        c = shown[t] if t != None else None
        for f in range(STEPS * ROTATIONS_PER_TARGET):
            step = f % STEPS
            sweep_angle = step * 360 / STEPS
            scope = render.Stack(
                children = [render.Box(width = 32, height = 32)] + static +
                           sweep_layer(lines, step) +
                           blip_layer(craft, sweep_angle, t) + home,
            )
            frames.append(render.Row(
                children = [
                    scope,
                    render.Box(width = 1, height = 32, color = "#0b3d0b"),
                    render.Padding(pad = (1, 0, 0, 0), child = render.Box(width = 30, height = 32, child = panel(c, len(craft), (f // 4) % 2 == 0))),
                ],
            ))

    return render.Root(delay = DELAY_MS, child = render.Animation(children = frames))
