# Inbox

Inbox is cmux's unified, local-first activity surface. It sits in the right
sidebar (the former Feed slot) and merges two kinds of activity into one
date-grouped timeline:

- **Agents** — everything the [Feed](feed.md) tracks (permission requests,
  plan approvals, questions, tool activity), mirrored one-way into Inbox.
- **External sources** — Slack, Gmail, Discord, iMessage, and generic pushed
  events, each linked once and then synced on demand or in the background.

All data is normalized into one schema and stored locally in
`~/.cmuxterm/inbox.sqlite3`. Credentials live only in the local credential
vault (Keychain when the build is entitled, an owner-only file at
`~/.cmuxterm/inbox-tokens.json` otherwise). AI drafting runs only when you ask
for a draft, and **external replies are never sent until you approve Send.**

## Linking an integration

Open **Settings → Integrations** and click **Connect…** on a source. Each
source has a guided setup:

### Gmail (one-click)

Click **Sign in with Google**. cmux opens your browser to Google's consent
screen using a loopback redirect with PKCE (RFC 8252), exchanges the code for
an access + refresh token, and stores a refreshable credential in the vault.
Access tokens are renewed automatically, so you link once and it keeps
syncing.

One-click sign-in needs a Google OAuth client id. Add it to
`~/.config/cmux/cmux.json`:

```json
{
  "integrations": {
    "gmail": {
      "client_id": "XXXXXX.apps.googleusercontent.com",
      "client_secret": "optional-for-web-clients"
    }
  }
}
```

Use a **Desktop** OAuth client (no secret required) from the Google Cloud
console, with the Gmail API enabled. If no client id is configured, the sheet
falls back to pasting a raw access token.

Linking seeds the inbox with the 25 most recent unread messages; everything
that arrives after that flows in completely through Gmail's history cursor.
Older backlog beyond the seed is intentionally not imported.

### Slack

1. Create a Slack app and add the bot scopes `channels:history`,
   `channels:read`, and `chat:write`.
2. Install the app and copy the **Bot User OAuth Token** (`xoxb-…`).
3. Paste it into the Connect sheet.

You do **not** configure channel IDs. On each sync cmux calls
`users.conversations` to discover every channel, DM, and group the bot belongs
to, then backfills them (rotating through them in bounded windows to respect
Slack rate limits). Invite the bot to a channel with `/invite @yourbot` and it
appears on the next sync.

### Discord

Create a bot in the Discord Developer Portal, enable the **Message Content**
intent, invite it to your server, and paste the bot token.

### iMessage

iMessage uses the local `cmux-imsg` helper, which reads the Messages database
(`~/Library/Messages/chat.db`) directly and sends replies through Messages.app.
No data leaves your Mac. The helper requires **Full Disk Access**: grant it to
cmux in System Settings → Privacy & Security → Full Disk Access, then quit and
reopen cmux. Build and install the helper with:

```bash
cd tools/cmux-imsg && swift build -c release
mkdir -p ~/.cmuxterm/bin && cp .build/release/cmux-imsg ~/.cmuxterm/bin/
```

Release builds bundle the helper at `Contents/Resources/cmux-imsg`.

### App Notifications (every Mac app, zero credentials)

The `notifications` source reads the local macOS Notification Center store
through the `cmux-notif` helper, so every delivered notification — Slack,
Mail, Discord, calendars, anything — lands in the Inbox with no per-app
setup. Nothing leaves your Mac, and cmux's own notifications are excluded to
prevent feedback loops. It needs the same one-time **Full Disk Access** grant
as iMessage. Build alongside the iMessage helper:

```bash
cd tools/cmux-imsg && swift build -c release
cp .build/release/cmux-notif ~/.cmuxterm/bin/
```

### Generic

No credentials. Push normalized events from your own tools:

```bash
cmux inbox push --json '{"source":"generic","title":"Deploy done","body":"…","actionable":true}'
```

## CLI

```bash
cmux integrations list                       # accounts and status
cmux integrations connect slack --token-stdin
cmux integrations sync all
cmux inbox list [--source slack] [--unread|--actionable]
cmux inbox search "<query>"
cmux inbox draft <thread-id> [instruction]
cmux inbox send <draft-id>                   # explicit approval to send
```

Tokens are only accepted via `--token-env <NAME>` or `--token-stdin`, never as
a positional argument, so they stay out of shell history.
