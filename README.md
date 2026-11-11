# Tidbyt widgets

Custom [Pixlet](https://github.com/tidbyt/pixlet) widgets for a Tidbyt, kept fresh
by an AWS Lambda function. A Tidbyt only shows images it's sent, so Lambda renders
each widget on a schedule and pushes it to the device in the background, updating
that widget's slot in the rotation without interrupting what's on screen.

| Sun Arc (day) | Sun Arc (night) | Flights Overhead | Hello World |
|---|---|---|---|
| ![](docs/sun_arc_day.gif) | ![](docs/sun_arc_night.gif) | ![](docs/flights_overhead.gif) | ![](docs/hello_world.gif) |

| Stock Watch | Sectors | Stock Alert | Market Map |
|---|---|---|---|
| ![](docs/stock_watch.gif) | ![](docs/sectors.gif) | ![](docs/stock_alert.gif) | ![](docs/market_map.gif) |

## Widgets

- **Sun Arc** (`apps/sun_arc.star`): an abstract view of the day. A plain disc for
  the sun moves along a thin arc from sunrise to sunset over flat bands of sky color,
  with rings rippling out from it. At night it becomes a hollow ring for the moon. The
  palette follows the time of day. Shows sunrise and sunset times and how long is left.
  Config: `lat`, `lng`, `tz`.
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
- **Stock Watch** (`apps/stocks.star`): cycles through a list of tickers. Each one
  shows its price, the change since the previous close and its volume pace (today's
  volume against the same point of the day over the past month). Below is the day's
  price as a glowing area chart, next to a sideways histogram of the volume traded at
  each price: deep blue (little) to cyan (a lot), with the busiest price in amber. Set
  `tickers` to comma-separated Yahoo symbols, optionally `SYMBOL:Label` (default
  `^GSPC:S&P,TSLA,SPCX`), and `seconds` per ticker. Data from Yahoo Finance's chart
  API, no key needed, with Nasdaq's feed as a fallback when Yahoo's is stale.
- **Market Map** (`apps/market_map.star`, off by default): a treemap of the most
  traded US stocks. A tile's area is the dollar volume traded so far today and its
  color is the change since the previous close. A glint of light crosses the tiles
  trading at an unusually high volume, and labels fade between ticker and percent
  change. Config: `count`, `scale`, `unusual`. Data from Yahoo Finance's "most active"
  screener. To turn it on, remove `"enabled": false` from its entry in
  `apps.example.json`.
- **Sectors** (`apps/sectors.star`): what is moving, by sector. The eleven S&P 500
  sectors as bars sorted from strongest to weakest, with the S&P 500 as a dotted line
  and an amber tip on sectors trading at unusually high volume. A highlight walks
  along the bars while the header names each sector, its change and its volume pace.
  Data from Yahoo Finance's chart API for the sector SPDR funds.
- **Stock Alert** (`apps/stock_alert.star`): a full-screen alert when a watched ticker
  makes a big move. It is not in the rotation: the Lambda checks prices every minute
  (`lambda/alerts.py`) and pushes it to the front of the Tidbyt when a ticker's change
  since the previous close crosses a new multiple of its step (with a step of 3: at
  ±3%, ±6%, ±9%), once per level per day. Set `tickers` as `SYMBOL[:Label[:Step]]`
  (default `^GSPC:S&P:1,TSLA,SPCX`) and the default `step`. To see it now:
  `aws lambda invoke --function-name tidbyt-widgets --cli-binary-format raw-in-base64-out --payload '{"apps":["alert"],"alert_test":true}' /dev/stdout`
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
