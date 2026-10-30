# Tidbyt widgets

Custom [Pixlet](https://github.com/tidbyt/pixlet) widgets for a Tidbyt, kept fresh
by an AWS Lambda function. A Tidbyt only shows images it's sent, so Lambda renders
each widget on a schedule and pushes it to the device in the background, updating
that widget's slot in the rotation without interrupting what's on screen.

| Sun Arc (day) | Sun Arc (night) | Flights Overhead | Hello World |
|---|---|---|---|
| ![](docs/sun_arc_day.gif) | ![](docs/sun_arc_night.gif) | ![](docs/flights_overhead.gif) | ![](docs/hello_world.gif) |

## Widgets

- **Sun Arc** (`apps/sun_arc.star`): the sun moves along an arc from sunrise to
  sunset, and a moon takes over at night. The sky color follows the time of day,
  clouds drift by during the day, and stars twinkle at night. Shows sunrise and sunset
  times and how long is left. Config: `lat`, `lng`, `tz`.
- **Flights Overhead** (`apps/flights_overhead.star`): a radar scope with live ADS-B
  aircraft near you, cycling through the nearest planes and helicopters. Data comes
  from airplanes.live (falling back to adsb.lol), both free with no key. Config: `lat`,
  `lng`, `radius_nm`, and optionally `river_offset_mi` / `river_bearing` to draw a
  river line.
- **Oura** (`apps/oura.star`): sleep, readiness and activity scores as three rings
  that fill up, with last night's sleep time, HRV and today's steps. The Lambda fetches
  the data from the Oura API v2 (`lambda/oura.py`) and passes it in, so the app holds no
  credentials. One-time setup: create an app at developer.ouraring.com with redirect
  URI `http://localhost:8765/callback`, put `OURA_CLIENT_ID` and `OURA_CLIENT_SECRET`
  in `.oura`, then run `python3 scripts/oura_login.py`. Tokens are stored in SSM
  (`/oura/credentials`). Gen3+ rings need an active Oura membership for API access.
- **Stock Watch** (`apps/stocks.star`): cycles through a list of tickers, each with
  its price, change since the previous close and an intraday sparkline
  with a blinking dot on the latest price (dotted line = previous close). Set `tickers` to comma-separated Yahoo
  symbols, optionally `SYMBOL:Label` (default `^GSPC:S&P,TSLA,SPCX`), and `seconds`
  per ticker. Data from Yahoo Finance's chart API, no key needed.
- **Hello World** (`apps/hello_world.star`): the smallest possible example.

## How it works

```
apps/*.star          one Pixlet app per widget
apps.example.json    widget list that gets deployed (personal values come from APPS_JSON)
lambda/              Lambda handler and Dockerfile (Python + Pixlet, arm64)
deploy.sh            one-time AWS setup and infrastructure changes
.github/workflows/   build, smoke-test and deploy on every push to main
```

- **Lambda** (`tidbyt-widgets`) runs from a container image with Pixlet inside. On
  each run it renders the widgets that are due and pushes them to the Tidbyt API.
- **EventBridge Scheduler** starts it every minute from 5 AM to midnight and every 10
  minutes overnight, in local time.
- **The Tidbyt API token** is stored in SSM Parameter Store (`/tidbyt/api-token`,
  SecureString). Your device ID is set in the Lambda's environment.
- **GitHub Actions** builds the image on an arm64 runner and renders every widget as a
  smoke test. On `main`, it then pushes the image to ECR and updates the Lambda. It
  signs in to AWS through OIDC, so the repo holds no AWS keys.
- **Pushes only update the image.** Changes to schedules, IAM roles or Lambda settings
  need `./deploy.sh`. Scheduled runs are not retried, since the next run does the same job.

## Add a widget

1. Put `my_widget.star` in `apps/` and preview it with `pixlet serve apps/my_widget.star`.
2. Add it to `apps.example.json`, which is the widget list that gets deployed:
   ```json
   {"id": "mywidget", "file": "my_widget.star", "every": 30, "config": {}}
   ```
   - `id`: the widget's slot in the Tidbyt rotation (letters and numbers)
   - `every`: refresh interval in minutes (1 = every run). Overnight, widgets with
     `every` of 10 or less refresh on each 10-minute run.
   - `config`: values passed to the app (`config.get("key")`)
   - `"enabled": false` skips it
3. Personal values (your location) stay out of the repo, in the `APPS_JSON` secret.
   On deploy, each widget in it is laid over the one with the same id in
   `apps.example.json` (config merged key by key, see `scripts/merge_apps.py`). Only
   update it if the new widget needs a private value: `gh secret set APPS_JSON < apps.json`
4. Push to `main`.

## Set it up yourself

You need a Tidbyt (get the device ID and API key from the Tidbyt app under Settings →
General → Get API Key), an AWS account, Docker and the AWS CLI.

```bash
aws ssm put-parameter --name /tidbyt/api-token --type SecureString --value '<api-key>'
echo 'DEVICE_ID=<device-id>' > .env
cp apps.example.json apps.json      # then set your location
./deploy.sh                         # creates ECR, IAM roles, Lambda, schedules
```

For deploy-on-push from your fork, create an IAM role that GitHub Actions can assume
through OIDC for your repo's `main` branch, with permission to push to the
`tidbyt-widgets` ECR repository and run `lambda:UpdateFunctionCode` on the function.
Then set the repository variable `AWS_ROLE_ARN` to that role and the secret `APPS_JSON`
to your `apps.json`.

## Useful commands

```bash
# Refresh every widget now
aws lambda invoke --function-name tidbyt-widgets --cli-binary-format raw-in-base64-out --payload '{"apps":"all"}' /dev/stdout

# Recent logs
aws logs tail /aws/lambda/tidbyt-widgets --since 1h
```

- **Remove a widget from the rotation:** taking it out of `apps.json` stops its
  refreshes, but its last image stays on the device. Delete it with
  `curl -X DELETE -H "Authorization: Bearer $TOKEN" https://api.tidbyt.com/v0/devices/<device-id>/installations/<id>`.
- **Pixlet quirk:** Pixlet 0.34 treats every `.star` file in a folder as one app, so
  the Lambda copies each widget into a folder of its own before rendering it.

## License

MIT
