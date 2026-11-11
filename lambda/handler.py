"""
Lambda entry point: render Pixlet apps and push them to a Tidbyt.

The apps live in apps/*.star and are listed in apps.json. Each entry:
  id       installation ID, i.e. the app's slot in the Tidbyt rotation
  file     .star file in apps/
  every    refresh interval in minutes, against a 1-minute base. Overnight the
           schedule only runs every 10 minutes, so apps with every <= 10 run on
           each night run.
  config   optional key/value pairs passed to the app
  enabled  optional, false to skip the app
  source   optional, "oura" to fetch Oura data and pass it as config `data`

Invoke with {"apps": ["sunarc", ...]} to refresh those apps now regardless
of their interval, or {"apps": "all"} for every enabled app. The night schedule
sends {"night": true}.

Environment:
  DEVICE_ID    Tidbyt device ID
  TOKEN_PARAM  SSM parameter name holding the Tidbyt API token (SecureString)
  OURA_PARAM   SSM parameter with the Oura credentials (default /oura/credentials)
  DRY_RUN      if "1", render only and skip the push
"""

import base64
import json
import os
import shutil
import subprocess
import time
import urllib.request

import boto3

import oura

ROOT = os.path.dirname(os.path.abspath(__file__))
APPS_DIR = os.path.join(ROOT, "apps")
TICK_MINUTES = 1  # must match the daytime schedule
NIGHT_MINUTES = 10  # must match the overnight schedule
PUSH_URL = "https://api.tidbyt.com/v0/devices/{}/push"

_token = None


def get_token():
    global _token
    if _token is None:
        ssm = boto3.client("ssm")
        resp = ssm.get_parameter(Name=os.environ["TOKEN_PARAM"], WithDecryption=True)
        _token = resp["Parameter"]["Value"]
    return _token


def load_apps():
    with open(os.path.join(ROOT, "apps.json")) as f:
        return [a for a in json.load(f)["apps"] if a.get("enabled", True)]


def is_due(app, now, night=False):
    every = max(1, app.get("every", 10) // TICK_MINUTES)
    if night and every <= NIGHT_MINUTES:
        return True
    # Round to the nearest tick so small schedule jitter doesn't skip a run.
    tick = round(now / (TICK_MINUTES * 60))
    return tick % every == 0


def render(app):
    # Pixlet treats every .star file in a folder as one applet, so give each
    # app a folder of its own.
    work = f"/tmp/apps/{app['id']}"
    os.makedirs(work, exist_ok=True)
    src = os.path.join(work, os.path.basename(app["file"]))
    shutil.copyfile(os.path.join(APPS_DIR, app["file"]), src)

    config = dict(app.get("config", {}))
    if app.get("source") == "oura":
        config["data"] = json.dumps(oura_data(config.get("tz", "America/New_York")))

    out = f"/tmp/{app['id']}.webp"
    args = ["pixlet", "render", src, "-o", out]
    args += [f"{k}={v}" for k, v in config.items()]
    try:
        subprocess.run(args, check=True, capture_output=True, text=True, env={**os.environ, "HOME": "/tmp"})
    except subprocess.CalledProcessError as e:
        raise RuntimeError(f"pixlet render failed: {e.stderr.strip()}") from e
    with open(out, "rb") as f:
        return f.read()


def oura_data(tz):
    try:
        return oura.summary(tz)
    except oura.NotConnected:
        return {"error": "not connected"}
    except Exception as e:
        # The smoke test has no AWS credentials: render the error screen instead.
        if os.environ.get("DRY_RUN") == "1":
            return {"error": "no data"}
        raise RuntimeError(f"oura: {e}") from e


def push(app_id, image):
    body = json.dumps({
        "image": base64.b64encode(image).decode(),
        "installationID": app_id,
        "background": True,  # update the rotation slot without interrupting the display
    }).encode()
    req = urllib.request.Request(
        PUSH_URL.format(os.environ["DEVICE_ID"]),
        data=body,
        method="POST",
        headers={"Authorization": f"Bearer {get_token()}", "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=20) as resp:
        return resp.status


def lambda_handler(event, context):
    apps = load_apps()
    requested = (event or {}).get("apps")
    if requested == "all":
        selected = apps
    elif requested:
        selected = [a for a in apps if a["id"] in requested]
    else:
        now = time.time()
        night = bool((event or {}).get("night"))
        selected = [a for a in apps if is_due(a, now, night)]

    results, failed = {}, []
    for app in selected:
        try:
            image = render(app)
            if os.environ.get("DRY_RUN") == "1":
                results[app["id"]] = f"rendered {len(image)} bytes"
            else:
                results[app["id"]] = f"pushed {len(image)} bytes (HTTP {push(app['id'], image)})"
        except Exception as e:  # keep going so one broken app doesn't block the rest
            results[app["id"]] = f"error: {e}"
            failed.append(app["id"])

    print(json.dumps(results))
    if failed:
        raise RuntimeError(f"apps failed: {', '.join(failed)}; results: {json.dumps(results)}")
    return results
