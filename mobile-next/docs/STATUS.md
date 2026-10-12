# cmux-next mobile (native): status

Loop log for the agent building this. Updated in place.

## Works (verified 2026-10-12, recorded UI tests on sim `cnm-app-1` on mini-cmux8s)
- Backend live: https://cmux-next-mobile-native.debussy.workers.dev (39/39 smoke).
- Sign up with email code (test domain), pairing with `cnm-host` code, WebRTC link from the
  simulator (cmux8) to the host on mini-cmux-austin-mini-0 through Cloudflare signaling.
- Chief conversation: messages round-trip, typing indicator, Claude-backed replies split into bubbles.
- Agent chat: Claude Code via claude-agent-acp on the host; tool rows, markdown, turn summary.
- Terminal: Ghostty (MANUAL IO) renders the remote zsh; key bar; typing works.

## Hosts
- Build/simulator: mini-cmux8s-mac-mini (`scripts/remote.sh`, `scripts/sim-flow.sh`).
- Distant Mac host: mini-cmux-austin-mini-0, `~/cnm/host/bin/cnm-host serve --state ~/cnm/host/state`, log `~/cnm/host/host.log`.
- Test account: aziz-native@test.cmux.dev, code in ~/.secrets/cmux-next-mobile-native-test-login.

## Blocked on the user
- TURN: needs `TURN_KEY_ID`/`TURN_KEY_API_TOKEN` Worker secrets (1Password item; `op` signed out). STUN-only now.
- Email codes for real addresses: Cloudflare Email Sending domain (DNS change).
- Real iPhone install: phone not connected; device signing needs a team + bundle id registration.

## Next
- iMessage parity pass from docs/IMESSAGE-SPEC.md (capture agent running).
- Recorded animation verification (drawer, push, bubble send) with frame analysis vs references.
- Demo checkpoint ~15:05 PT: device + Mac builds.
