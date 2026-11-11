"""
Big-move alerts for watched tickers.

A ticker alerts when its change since the previous close crosses a new
multiple of its step: with a step of 3, at +3%, +6%, +9% and at -3%, -6%,
and so on. Each level alerts once a day per direction, so a price hovering
around a level stays quiet. The handler pushes the alert screen to the front
of the Tidbyt instead of into the rotation.

What has already alerted is kept in one SSM parameter (ALERT_PARAM, default
/tidbyt/alert-state) as JSON: {symbol: {"day": "2026-11-11", "up": 1, "down": 0}}.

Tickers are "SYMBOL[:Label[:Step]]", comma-separated, e.g.
"^GSPC:S&P:1,TSLA,SPCX::5". Prices come from Yahoo Finance's chart API.
"""

import datetime
import json
import os
import time
import urllib.parse
import urllib.request
from zoneinfo import ZoneInfo

import boto3

URL = "https://query1.finance.yahoo.com/v8/finance/chart/{}?range=1d&interval=5m"
HEADERS = {"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)"}
FRESH_SECS = 20 * 60  # only alert on prices that are trading now
DEFAULT_TICKERS = "^GSPC:S&P:1,TSLA,SPCX"


def _param():
    return os.environ.get("ALERT_PARAM", "/tidbyt/alert-state")


def _load_state(ssm):
    try:
        resp = ssm.get_parameter(Name=_param())
    except ssm.exceptions.ParameterNotFound:
        return {}
    return json.loads(resp["Parameter"]["Value"])


def _save_state(ssm, state):
    ssm.put_parameter(Name=_param(), Value=json.dumps(state), Type="String", Overwrite=True)


def parse_tickers(text, default_step):
    out = []
    for item in text.split(","):
        parts = item.strip().split(":")
        if not parts[0]:
            continue
        symbol = parts[0]
        label = parts[1] if len(parts) > 1 and parts[1] else symbol.replace("^", "")
        step = float(parts[2]) if len(parts) > 2 and parts[2] else default_step
        out.append((symbol, label, step))
    return out


def quote(symbol):
    """Latest price, previous close, the day's closes and the trade time."""
    req = urllib.request.Request(URL.format(urllib.parse.quote(symbol)), headers=HEADERS)
    with urllib.request.urlopen(req, timeout=15) as resp:
        result = json.load(resp)["chart"]["result"][0]
    meta = result["meta"]
    closes = [c for c in result["indicators"]["quote"][0].get("close") or [] if c is not None]
    price = meta.get("regularMarketPrice") or (closes[-1] if closes else None)
    prev = meta.get("chartPreviousClose") or meta.get("previousClose")
    if not price or not prev:
        return None
    traded = meta.get("regularMarketTime") or 0
    tz = ZoneInfo(meta.get("exchangeTimezoneName") or "America/New_York")
    return {
        "price": price,
        "prev": prev,
        "closes": closes or [prev, price],
        "traded": traded,
        "day": datetime.datetime.fromtimestamp(traded, tz).strftime("%Y-%m-%d"),
    }


def check(config, force=False):
    """Alerts due now, as data for apps/stock_alert.star. With force, every
    ticker alerts and nothing is remembered (for previews and tests)."""
    tickers = parse_tickers(config.get("tickers", DEFAULT_TICKERS), float(config.get("step", "3")))

    ssm, state = None, {}
    if not force:
        ssm = boto3.client("ssm")
        state = _load_state(ssm)

    found, changed = [], False
    for symbol, label, step in tickers:
        try:
            q = quote(symbol)
        except Exception as e:  # one bad ticker must not silence the others
            print(f"alerts: {symbol}: {e}")
            continue
        if q is None:
            continue

        pct = (q["price"] - q["prev"]) / q["prev"] * 100
        up = pct >= 0
        level = int(abs(pct) // step)

        if not force:
            if time.time() - q["traded"] > FRESH_SECS:
                continue  # market closed, or the feed is stale
            seen = state.get(symbol, {})
            if seen.get("day") != q["day"]:
                seen = {"day": q["day"], "up": 0, "down": 0}
            side = "up" if up else "down"
            if level <= seen[side]:
                continue
            seen[side] = level
            state[symbol] = seen
            changed = True

        found.append({
            "label": label,
            "pct": round(pct, 2),
            "up": up,
            "level": round(max(1, level) * step * (1 if up else -1), 2),
            "prev": q["prev"],
            "closes": [round(c, 4) for c in q["closes"]],
        })

    if changed:
        _save_state(ssm, state)
    return found
