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


def _latest(rows):
    return max(rows, key=lambda r: r.get("day", "")) if rows else {}


def summary(tz="America/New_York"):
    """Latest scores and a few stats, as passed to apps/oura.star."""
    token = access_token()
    today = datetime.datetime.now(ZoneInfo(tz)).date()
    start, end = (today - datetime.timedelta(days=2)).isoformat(), (today + datetime.timedelta(days=1)).isoformat()

    sleep = _latest(_get(token, "daily_sleep", start, end))
    ready = _latest(_get(token, "daily_readiness", start, end))
    activity = _latest(_get(token, "daily_activity", start, end))
    # The main sleep period of the latest night, for duration, HRV and resting HR.
    night = _latest([s for s in _get(token, "sleep", start, end) if s.get("type") == "long_sleep"])

    return {
        "day": sleep.get("day") or ready.get("day"),
        "sleep": sleep.get("score"),
        "readiness": ready.get("score"),
        "activity": activity.get("score"),
        "steps": activity.get("steps"),
        "sleep_secs": night.get("total_sleep_duration"),
        "hrv": night.get("average_hrv"),
        "rhr": night.get("lowest_heart_rate"),
    }
