#!/usr/bin/env python3
"""
One-time Oura sign-in. Run it on your Mac from the project root:

    python3 scripts/oura_login.py

Before that, create an app at https://developer.ouraring.com with the redirect
URI http://localhost:8765/callback, and put its credentials in .oura (not
committed):

    OURA_CLIENT_ID=...
    OURA_CLIENT_SECRET=...

The script opens Oura's consent page in your browser, catches the redirect,
stores the tokens in SSM (/oura/credentials, SecureString) for the Lambda, and
prints your latest scores as a check. Needs only the Python standard library
and the AWS CLI. Re-run it if the Lambda ever reports "not connected".
"""

import http.server
import json
import os
import secrets
import shutil
import subprocess
import sys
import time
import urllib.parse
import urllib.request
import webbrowser

PORT = 8765
REDIRECT = f"http://localhost:{PORT}/callback"
AUTHORIZE_URL = "https://cloud.ouraring.com/oauth/authorize"
TOKEN_URL = "https://api.ouraring.com/oauth/token"
SCOPES = "daily heartrate personal"
PARAM = "/oura/credentials"
REGION = os.environ.get("REGION", "us-east-1")


def read_env(path):
    vals = {}
    with open(path) as f:
        for line in f:
            if "=" in line and not line.lstrip().startswith("#"):
                k, v = line.strip().split("=", 1)
                vals[k.strip()] = v.strip().strip("'\"")
    return vals


def wait_for_code(state):
    result = {}

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query)
            if q.get("state", [""])[0] != state:
                result["error"] = "state mismatch"
            elif "code" in q:
                result["code"] = q["code"][0]
            else:
                result["error"] = q.get("error", ["no code"])[0]
            ok = "code" in result
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.end_headers()
            msg = "Oura connected. You can close this tab." if ok else f"Oura sign-in failed: {result.get('error')}"
            self.wfile.write(f"<h2>{msg}</h2>".encode())

        def log_message(self, *args):
            pass

    server = http.server.HTTPServer(("localhost", PORT), Handler)
    while not result:
        server.handle_request()
    if "error" in result:
        sys.exit(f"Sign-in failed: {result['error']}")
    return result["code"]


def main():
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    env = read_env(os.path.join(root, ".oura"))
    client_id, client_secret = env["OURA_CLIENT_ID"], env["OURA_CLIENT_SECRET"]

    state = secrets.token_urlsafe(16)
    url = AUTHORIZE_URL + "?" + urllib.parse.urlencode({
        "response_type": "code",
        "client_id": client_id,
        "redirect_uri": REDIRECT,
        "scope": SCOPES,
        "state": state,
    })
    print("Opening Oura sign-in. If no browser opens, visit:\n" + url)
    webbrowser.open(url)
    code = wait_for_code(state)

    body = urllib.parse.urlencode({
        "grant_type": "authorization_code",
        "code": code,
        "redirect_uri": REDIRECT,
        "client_id": client_id,
        "client_secret": client_secret,
    }).encode()
    with urllib.request.urlopen(urllib.request.Request(TOKEN_URL, data=body, method="POST"), timeout=20) as resp:
        tok = json.load(resp)

    creds = {
        "client_id": client_id,
        "client_secret": client_secret,
        "refresh_token": tok["refresh_token"],
        "access_token": tok["access_token"],
        "expires_at": int(time.time()) + int(tok.get("expires_in", 86400)),
    }
    aws = shutil.which("aws", path="/opt/homebrew/bin") or "aws"
    subprocess.run([aws, "ssm", "put-parameter", "--region", REGION, "--name", PARAM, "--type", "SecureString",
                    "--overwrite", "--value", json.dumps(creds)], check=True, stdout=subprocess.DEVNULL)
    print(f"Saved Oura credentials to SSM {PARAM}.")

    # Show the latest data as a check.
    headers = {"Authorization": f"Bearer {tok['access_token']}"}
    for name in ("daily_sleep", "daily_readiness", "daily_activity"):
        req = urllib.request.Request(f"https://api.ouraring.com/v2/usercollection/{name}", headers=headers)
        with urllib.request.urlopen(req, timeout=20) as resp:
            rows = json.load(resp).get("data", [])
        latest = max(rows, key=lambda r: r["day"]) if rows else {}
        print(f"  {name}: {latest.get('score', 'no data')} ({latest.get('day', '-')})")


if __name__ == "__main__":
    main()
