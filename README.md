# textstop

Replies STOP to political and marketing texts on macOS. Reads `chat.db` read-only, sends through
Messages.app, and stays in dry-run until you run `go-live`.

## Setup

Optional but recommended: `scripts/make-signing-identity.sh` creates a self-signed signing identity in
its own keychain (`~/Library/Application Support/textstop/`). Builds signed with it keep Full Disk Access
and Automation across rebuilds; ad hoc builds lose both every time.

1. iPhone: Settings > Apps > Messages > Text Message Forwarding > turn on this Mac.
2. `scripts/install.sh`, then add `~/Applications/TextStop.app` to Full Disk Access when prompted.
3. Approve the Messages automation prompt.
4. `~/Applications/TextStop.app/Contents/MacOS/textstop doctor` (once SMS has arrived, it reports forwarding as working).

Run commands from the installed binary. Running from a terminal uses the terminal's permissions, so
it doesn't prove the agent's permissions work; check `~/Library/Logs/textstop/agent.log` for that.

Rebuilding changes the ad hoc signature, so macOS may drop the grants. Re-add them after reinstalling.

## Use

    textstop log --stop      what it would send
    textstop log             every decision and why
    textstop report          likely scams, to report by hand
    textstop status
    textstop test-send 12345 # sends HELP, with confirmation
    textstop go-live         # refused for the first 7 days without --force
    textstop dry-run         # back to logging only

## When it replies

All of these must hold (`Sources/TextStopCore/Policy.swift`):

- Sender isn't in Contacts, and you've never sent them anything but STOP or HELP
- 1:1 chat over SMS or RCS, from a phone number or short code
- Not a verification code, transactional alert, or likely scam
- Received in the last 24 hours and after the first run
- Classified political or marketing, and the message offers an opt-out (`no-optout on` relaxes this)
- No STOP to this sender in 30 days, and fewer than 20 sends in 24 hours

The reply is always the fixed text "STOP". If Contacts comes back empty, the run stops.

## Cloud classifier (off by default)

Only messages with opt-out wording that the keyword pass couldn't categorize are sent, with digit
runs masked and no sender. It can only return a category label.

    security add-generic-password -s textstop-anthropic-api-key -a textstop -T /usr/bin/security -w
    textstop cloud on

Set `TEXTSTOP_MODEL` in the launch agent plist to change the model (default `claude-opus-5-5`).

## Campaign log

`textstop campaigns [days] [--out file.csv]` exports every political text from unknown senders still in
Messages (default: last 365 days, to `~/Documents/political-texts.csv`): received time, sender number,
campaign, how the campaign was identified, link hosts, and the full text. Campaign names come from, in
order: the sender's own unsubscribe confirmation, a "Paid for by" disclaimer, the text naming itself
("It's Mary Peltola"), or the sign-off above "Stop2End". A confirmed name carries over to other numbers
that link to the same domain. It reads Messages, so deleted conversations drop out.

## Spam reporting (off by default)

`textstop spam-report on` reports each text that got a real STOP to 7726, the US carriers' shared spam
line: it forwards the text, waits for the carrier to ask for the sender, then replies with the number.
One report at a time, so replies pair up; it gives up on one after 30 minutes without an answer.
Only the spam text and the sender's number go to 7726. `spam-report backfill [hours]` queues STOPs
already sent (default 24 hours). `spam-report` shows counts.

Deleting the conversation afterwards isn't possible: Messages rejects `delete chat` from AppleScript
(error -10000) on macOS 14.

## Metrics (off by default)

Each run can push counts to a Prometheus Pushgateway: decisions by action and category, sends by
result, mode, and run health. No phone numbers or message text.

1. Run a Pushgateway (e.g. `quay.io/prometheus/pushgateway:v1.11.5` on port 9091) and have Prometheus
   scrape it with `honor_labels: true` (`deploy/prometheus-scrape.yml`). `deploy/textstop-alerts.yml` has
   optional alert rules.
2. `textstop metrics http://pushgateway.local:9091` (test-pushes before saving; `textstop metrics off` stops it).

The Pushgateway has no authentication, so anything on the LAN can push to it.

## Data

`~/Library/Application Support/textstop/state.db` holds senders and 160-character previews with long
digit runs masked. Verification text is never stored.

## Tests

    swift run textstop-tests

XCTest isn't available with Command Line Tools alone, so tests are a plain executable.
