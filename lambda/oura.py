"""
Oura API v2 client for the Lambda.

Credentials live in one SSM SecureString parameter (OURA_PARAM, default
/oura/credentials) as JSON: client_id, client_secret, refresh_token, and the
cached access_token / expires_at. scripts/oura_login.py creates it.

Oura refresh tokens are single use, so every refresh writes the new pair back
to SSM right away. The access token lasts about a day, so that is rare.
"""

import datetime
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request
from zoneinfo import ZoneInfo

import boto3

API = "https://api.ouraring.com/v2/usercollection/"
TOKEN_URL = "https://api.ouraring.com/oauth/token"


class NotConnected(Exception):
    pass


def _param():
    return os.environ.get("OURA_PARAM", "/oura/credentials")


def _load_creds(ssm):
    try:
        resp = ssm.get_parameter(Name=_param(), WithDecryption=True)
    except ssm.exceptions.ParameterNotFound:
        raise NotConnected("not connected")
    return json.loads(resp["Parameter"]["Value"])


def _post_form(url, fields):
    req = urllib.request.Request(url, data=urllib.parse.urlencode(fields).encode(), method="POST")
    with urllib.request.urlopen(req, timeout=20) as resp:
        return json.load(resp)


def access_token():
    ssm = boto3.client("ssm")
    creds = _load_creds(ssm)
    if creds.get("access_token") and creds.get("expires_at", 0) > time.time() + 300:
        return creds["access_token"]

    tok = _post_form(TOKEN_URL, {
        "grant_type": "refresh_token",
        "refresh_token": creds["refresh_token"],
        "client_id": creds["client_id"],
        "client_secret": creds["client_secret"],
    })
    creds.update(
        access_token=tok["access_token"],
        refresh_token=tok.get("refresh_token", creds["refresh_token"]),
        expires_at=int(time.time()) + int(tok.get("expires_in", 86400)),
    )
    ssm.put_parameter(Name=_param(), Value=json.dumps(creds), Type="SecureString", Overwrite=True)
    return creds["access_token"]


def _get(token, collection, start, end):
    qs = urllib.parse.urlencode({"start_date": start, "end_date": end})
    req = urllib.request.Request(f"{API}{collection}?{qs}", headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, timeout=20) as resp:
        return json.load(resp).get("data", [])


def _try_get(token, collection, start, end):
    """Like _get, but [] when the endpoint is off-limits (e.g. a scope we didn't ask for)."""
    try:
        return _get(token, collection, start, end)
    except urllib.error.HTTPError as e:
        if e.code in (401, 403, 404):
            return []
        raise


def _by_day(rows, pick=None):
    """{day: row}; with several rows a day, keep the one `pick` ranks highest."""
    out = {}
    for r in rows:
        d = r.get("day")
        if d and (d not in out or (pick and pick(r) > pick(out[d]))):
            out[d] = r
    return out


def _clock(ts):
    """'2026-10-29T23:41:00-04:00' -> '23:41'."""
    return ts[11:16] if ts and len(ts) >= 16 else None


def summary(tz="America/New_York", days=7):
    """The last `days` days of each signal, oldest first, as passed to apps/oura.star."""
    token = access_token()
    today = datetime.datetime.now(ZoneInfo(tz)).date()
    dates = [(today - datetime.timedelta(days=n)).isoformat() for n in range(days - 1, -1, -1)]
    start, end = dates[0], (today + datetime.timedelta(days=1)).isoformat()

    sleep = _by_day(_get(token, "daily_sleep", start, end))
    ready = _by_day(_get(token, "daily_readiness", start, end))
    activity = _by_day(_get(token, "daily_activity", start, end))
    # The main sleep period of each night, for HRV, resting HR and so on.
    nights = _by_day(
        [s for s in _get(token, "sleep", start, end) if s.get("type") == "long_sleep"],
        pick=lambda s: s.get("total_sleep_duration") or 0,
    )
    stress = _by_day(_try_get(token, "daily_stress", start, end))
    spo2 = _by_day(_try_get(token, "daily_spo2", start, end))

    def series(rows, get):
        return [get(rows[d]) if d in rows else None for d in dates]

    def stress_min(r):
        return None if r.get("stress_high") is None else round(r["stress_high"] / 60)

    last_night = nights.get(dates[-1], {})
    return {
        "series": {
            "sleep": series(sleep, lambda r: r.get("score")),
            "readiness": series(ready, lambda r: r.get("score")),
            "activity": series(activity, lambda r: r.get("score")),
            "hrv": series(nights, lambda r: r.get("average_hrv")),
            "rhr": series(nights, lambda r: r.get("lowest_heart_rate")),
            "temp": series(ready, lambda r: r.get("temperature_deviation")),
            "breath": series(nights, lambda r: r.get("average_breath")),
            "spo2": series(spo2, lambda r: (r.get("spo2_percentage") or {}).get("average")),
            "steps": series(activity, lambda r: r.get("steps")),
            "cal": series(activity, lambda r: r.get("active_calories")),
            "stress": series(stress, stress_min),
            "deep": series(nights, lambda r: r.get("deep_sleep_duration")),
            "eff": series(nights, lambda r: r.get("efficiency")),
        },
        "bed": _clock(last_night.get("bedtime_start")),
    }
