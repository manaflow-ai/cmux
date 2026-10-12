# cmux-next native mobile

A native iOS client for cmux-next. The phone talks to the existing cmux-next
host (the cmux-tui daemon that the Mac app runs) over a transport-agnostic
link. The first link is WebRTC data channels, with Cloudflare STUN/TURN and a
Cloudflare Worker for signaling. Accounts, hosts and devices live in
PlanetScale. No other providers.

```
iPhone app ──HostLink(WebRTC DC)──> host bridge (Mac) ──unix socket──> cmux daemon
     │                                   │
     └──HTTPS/WSS──> Worker (signal DO, ICE creds) <──WSS──┘
                         │
                     PlanetScale (users, hosts, devices, pairings, push)
```

## Layout

| Path | What |
| --- | --- |
| `native-mobile/worker/` | Cloudflare Worker `cmux-next-native` (TypeScript, Durable Object `HostSignal`), PlanetScale schema in `schema.sql` |
| `native-mobile/Shared/` | SwiftPM package `CmuxNativeWire`: link protocol, signaling messages, host-service RPC types. Used by iOS and the host. |
| `native-mobile/host/` | SwiftPM package `CmuxNativeHost`: WebRTC host bridge library + `cmux-native-host` CLI. The Mac app embeds the library. |
| `native-mobile/ios/` | iOS app (xcodegen `project.yml`), SwiftUI + UIKit. |

## Link contract (transport agnostic)

`HostLink` gives reliable, ordered, message-framed channels by label:

- `daemon:<uuid>`: every message is one newline-terminated JSON line of the
  cmux-tui daemon protocol (v12). The bridge opens a fresh daemon socket
  connection per channel and splices it both ways. The bridge enforces the
  same allowlist as `CmuxNextMobile/DaemonLane/DaemonLanePolicy.swift`.
- `svc`: host services, newline JSON.
  - request `{"id":N,"method":"fs.list","params":{...}}`
  - response `{"id":N,"ok":true,"result":{...}}` or `{"id":N,"ok":false,"error":{"code":"...","message":"..."}}`
  - event `{"event":"feed.item","payload":{...}}`
  - Methods: `host.info`, `fs.list {path}`, `fs.stat {path}`,
    `fs.read {path, offset?, length?}` (base64 `data`, `size`, `mime`),
    `git.status {cwd}`, `git.diff {cwd, path?, staged?, base?}` (unified diff
    text plus per-file stats), `git.log {cwd, limit}`,
    `upload.put {name, data_b64, dir?}` (returns host path; chunked with
    `upload.begin/chunk/end` above 512 KiB), `session.refs {surface_id}`,
    `feed.list {limit}`, `feed.subscribe`, `feed.reply {item_id, text}`,
    `feed.answer {item_id, choice}`, `presence.set {visible}` (cmux is on
    screen; the host holds push alerts).

Data channels carry at most 16 KiB per message. The sender splits a line
into `{"frag":k,"of":n,"d":"..."}` envelopes only above that size.

## Signaling (Worker)

- `POST /v1/auth/apple` `{identity_token}` → `{user, session_token}`.
  `POST /v1/auth/dev` (test accounts only, guarded by a secret) for agents.
- `POST /v1/hosts/register` `{name, platform}` → `{host_id, host_secret, pairing_code}`.
  `POST /v1/hosts/pairing-code` (host auth) → new 8-symbol code, 10 min TTL.
- `POST /v1/pair` (user auth) `{code}` → `{host}`; the host joins the user.
- `GET /v1/hosts` (user auth) → hosts with presence.
- `GET /v1/ice` (user or host auth) → Cloudflare TURN `iceServers`, 24h TTL.
- `GET /v1/signal/:host_id` WebSocket upgrade, one Durable Object per host.
  Host connects with `host_secret`; phones with `session_token`.
  Messages: `{"t":"offer"|"answer"|"ice"|"bye","sid","sdp"?,"candidate"?}`.
  The DO stamps `from` and routes phone→host and host→phone by `sid`.
- Push (details in `worker/README.md`): `POST /v1/push/register`,
  `POST /v1/hosts/:id/events` (host posts attention events and Live
  Activity updates), `POST /v1/push/live-activity`, `POST /v1/push/action`
  (a notification answer, relayed to the host socket as `{"t":"action"}`).
  The host holds alerts while a phone reports `presence.set {visible:true}`
  on `svc`, and acts on an answer only for an event it posted, on that
  event's surface.

## iOS app shape

- Tabs (iOS 26 Liquid Glass tab bar): **Sessions**, **Feed**, **Settings** via profile.
- Sessions: host picker, workspaces → terminals list. Terminal screen: Ghostty
  (GhosttyNextKit) renderer, native scroll for non-TUI surfaces with scroll
  edge effects top and bottom, fixed grid for TUI (alternate screen), composer
  bar (text, Photos, Files, special keys), files/artifacts sheet, diff viewer.
- Feed: X-style posts from attention events, quote bubble of the prompt or
  response being answered, inline reply, question tool answers, WKWebView
  markdown body.
- Theme: cmux-next ink-and-gray with system materials. No blue accents.
