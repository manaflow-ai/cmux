# cmux-next mobile (native): status

Loop log for the agent building this. Updated in place.

## Works (verified 2026-10-12, recorded UI tests on sim `cnm-app-1` on mini-cmux8s)
- Backend live: https://cmux-next-mobile-native.debussy.workers.dev (39/39 smoke).
- Sign up with email code (test domain), pairing with `cnm-host` code, WebRTC link from the
  simulator (cmux8) to the host on mini-cmux-austin-mini-0 through Cloudflare signaling.
- Chief conversation: messages round-trip, typing indicator, Claude-backed replies split into bubbles.
- Agent chat: Claude Code via claude-agent-acp on the host; tool rows, markdown, turn summary.
- Terminal: Ghostty (MANUAL IO) renders the remote zsh; key bar; typing works.
- TURN: Worker secrets set from 1Password (`cmux-next-ios-wrtc` key). Forced relay-only run
  (`-cnm-relay-only`) connected to the distant mini via Cloudflare TURN and ran a terminal command.
- Two Macs on different networks (2026-10-12, run r21/r22): mini-cmux-austin-mini-0 (office,
  relay) and Aziz's other MacBook (direct, host/host candidates) connected at once; a Ghostty
  terminal on the MacBook printed `hi from Abdulaziz's MacBook Pro (2) on 27.2`. The MacBook host is
  stopped after each run (it is paired to the shared test account).
- Agent chat (ACP features verified on the distant mini, 2026-10-12): photo attachments (Claude described
  the photo), slash-command menu from `available_commands_update`, mode picker (`session/set_mode` → Plan),
  Plan mode with the plan rendered in the approval card, approve/deny edits with diffs, thinking, tool rows.
- Auth decision (user, 2026-10-12): Apple sign-in only for now. Email codes stay behind
  `-cnm-email-auth` for automated test accounts.

## Hosts
- Build/simulator: mini-cmux8s-mac-mini (`scripts/remote.sh`, `scripts/sim-flow.sh`).
- Distant Mac host: mini-cmux-austin-mini-0, `~/cnm/host/bin/cnm-host serve --state ~/cnm/host/state`, log `~/cnm/host/host.log`.
- Test account: aziz-native@test.cmux.dev, code in ~/.secrets/cmux-next-mobile-native-test-login.

## Blocked on the user
- Real iPhone install: phone not connected (build is ready in ~/cnm-builds/latest).

## Demo builds
- 2026-10-12 15:55: refreshed demo (Settings crash fix); 12/12 regression (r56). Same paths.
  dev.cmux.next.native, profile "cmux next native dev" incl. Aziz's iPhone) and ~/Applications/cmux Host.app
  (installed, not started). Phone was not connected (devicectl: unavailable), so not installed.
- Regression before the build: 8/8 UI flows passed (r27).

## Next
- iMessage parity pass from docs/IMESSAGE-SPEC.md (capture agent running).
- Recorded animation verification (drawer, push, bubble send) with frame analysis vs references.
- Demo checkpoint ~15:05 PT: device + Mac builds.
- Host restart mid-session (r48): the phone notices within ~3 s of the Mac leaving signaling, redials as soon
  as it is back (~4 s after restart), and a terminal whose shell died with the host shows
  "This terminal ended when cmux Host restarted" with a New terminal button that works.
- Agent resume (r49): after a host restart killed the agent, the next prompt restarted it with ACP `session/load` and it still remembered ("Pineapple"). ACP session ids persist as `<id>.acp`; replayed history is dropped.
- Terminal rotation (r50): the remote pty follows the phone grid, portrait 50x23 → landscape 96x6 (keyboard up).
- Terminal pinch-to-zoom (r51): font size via Ghostty binding actions; grid follows (50 → 43 columns).
- Codex agent (r60): codex-acp on the distant mini answered; its modes ("Auto review") and models ("6.1 Sol (low)") show as composer chips.
- Background 40 s and resume (r61): terminal keeps working. The simulator does not suspend sockets like a device; on a device the reconnect + re-attach path (verified in r48) takes over.
