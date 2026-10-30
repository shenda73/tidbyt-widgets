"""
Build the deployed apps.json: the widget list in apps.example.json, with your
personal settings (from the APPS_JSON secret) laid over it by id.

Each widget in the secret overrides the matching widget's fields, and its
config is merged key by key, so the secret only needs what differs (e.g.
your location). Widgets only in the secret are kept too. So a new widget
only needs adding to apps.example.json.

Usage: python3 scripts/merge_apps.py apps.example.json [secret.json] > apps.json
"""

import json
import sys


def merge(base, personal):
    out = {a["id"]: dict(a) for a in base["apps"]}
    for a in personal.get("apps", []):
        cur = out.setdefault(a["id"], {})
        config = {**cur.get("config", {}), **a.get("config", {})}
        cur.update(a)
        if config:
            cur["config"] = config
    return {"apps": list(out.values())}


if __name__ == "__main__":
    with open(sys.argv[1]) as f:
        base = json.load(f)
    personal = {}
    if len(sys.argv) > 2:
        with open(sys.argv[2]) as f:
            personal = json.load(f)
    json.dump(merge(base, personal), sys.stdout, indent=2)
    print()
