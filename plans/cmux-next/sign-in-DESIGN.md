# Every sign-in in one click

Status: design, 2026-11-25. Branch `feat-cmux-next`. Leo-Ask-Trace: ask-d45cba766c.
Asks: Leo, 2026-11-25 07:35Z, on the Claude setup token (paraphrased): the flow opens a large
two-step popup, a terminal, an email magic link, two code copies and pastes, and a token whose
pasted spaces break the field; "surely we can minimize the cruft all around here." Then 08:36Z:
"btw actually on the whole claude setup situation what about other ones? chatgpt? are there deeper
ergo things we can do wrt that? and other apps and whatnot? and also spruce up the signed in to
github page situation? maybe our auth too?"

Owners: model providers (sections 3 to 5): `cloud-claude-connect-ux`. GitHub, Settings >
Connections and MCP OAuth, cmux's own account, the signed-in page (section 6):
`signin-github-setup-ux`. One card component and this one doc serve both.

Related: [mcp-connect-DESIGN.md](mcp-connect-DESIGN.md), [cloud-github-auth-DESIGN.md](cloud-github-auth-DESIGN.md),
`cmux-tui/docs/model-connections.md`.

## 1. Rules every sign-in follows

1. **Inline, where the need arises.** A card in the chat (above the composer) or in the Settings
   row that needs it. No modal, no multi-step popup.
2. **One click.** The card has one button. Everything after it is the app's job, or the vendor's
   minimum (their consent page).
3. **In our browser.** The vendor page opens in the in-app browser sheet
   (`linkOpener.openSignInPage`), never a terminal, never the person's default browser.
4. **The app captures the secret.** A localhost callback, a device code the app polls, or a CLI
   driven in a hidden PTY. The person never copies or pastes a token, and a secret never reaches a
   log, the screen or argv; it goes straight to the Keychain.
5. **Progress line, then done.** The card shows one line (`Starting…`, `Waiting for you to sign in
   to Claude`, `Saving…`, or the error with Retry) and disappears when the chat starts.
6. **Reuse a local login** when the vendor supports it, with a one-line "Use your Mac's Codex
   login" instead of a fresh sign-in.
7. **Paste is the fallback, and it forgives.** Where a paste remains (API keys, a code the vendor
   insists on), the field strips every whitespace and zero-width character, checks the vendor's
   shape, and checks the key live before saving.
8. **One place lists them all,** each with a status pill (Connected, Expires soon, Signed out), and
   re-auth starts before expiry from the same card.

## 2. The card

`webviews/src/agent-session/acpmux/ConnectCard.tsx`. Props: provider, phase
(`idle | starting | signing_in | saving | error | done`), error, the one action, cancel, an
optional code field (the paste fallback, hidden until asked). Variants, all in the gallery:

- `card` (default): title, one button, the progress line under it.
- `row`: one line for a Settings list or a narrow composer.
- `steps`: the same card with "Step n of 3" for a first-run walkthrough.

The webview only draws phases. The flow (begin, wait, code, cancel) lives in the daemon (Rust)
and the Swift model drives it; React holds no logic beyond the phase it is told.

## 3. Model providers: before and after

Counts are from the code and the live walk; clicks + app switches + copies + pastes + email trips
+ terminals.

| Provider | Before | After (this work) | How |
|---|---|---|---|
| Claude (subscription) | ~19 steps: popup, terminal, `claude setup-token`, browser, email, magic link, copy code, paste, copy token, paste, fix spaces | 1 click + Claude's consent page | `claude_token.begin/wait/code/cancel`: the daemon runs `claude setup-token` in a hidden PTY, the in-app browser opens the sign-in, the localhost callback returns, the token goes to the Keychain |
| ChatGPT / Codex (subscription) | 2 clicks, 1 switch to the default browser | 1 click + OpenAI's consent page, in-app | `chatgpt.begin/wait`, the URL opened in the in-app sheet; an existing `~/.codex/auth.json` is offered as "Use your Mac's Codex login" |
| API keys (OpenAI, Anthropic, OpenRouter, Google, xAI) | ~4 clicks, 2 switches, 1 copy, 1 paste; a key wrapped across lines rejected; a wrong key found at the first turn | same paste, never rejected for whitespace, wrong key caught before save | all whitespace stripped, prefix shape, `connections/key.check` live GET |
| Cursor (Cloud machine) | 1 click, 1 browser trip | 1 click, in-app | `cursor-agent login` already finishes on its own; open its link in the sheet |
| Gemini / Antigravity | API key paste only on Cloud; local login in a terminal tab | key paste with rule 7; local login in a hidden PTY (next) | Google OAuth for the Gemini CLI is not yet driven anywhere |
| OpenCode | key paste from `opencode.ai/auth` | key paste with rule 7 | no OAuth to drive |

## 4. Skipping the email round trip

Claude's sign-in page sends a magic link only when the browser has no claude.ai session. The in-app
browser has its own cookie jar, so the first connect still asks for email once; after that the
session persists and a reconnect is the consent page only. Reusing the Mac's `claude` CLI login
(`claude-login` route) needs no sign-in at all for local chats; a Cloud chat needs its own token,
so it still goes through `setup-token`, once.

## 5. Local harness logins

`SettingsHarnesses.signInAgent` types `acpmux harness login -- <id>` into a terminal tab. Next: the
same begin/wait shape for each harness that has a headless login (`codex login --device-auth`,
`cursor-agent login`, `claude auth login --claudeai`), drawn as the card, with the terminal tab
kept only for a harness that has none.

## 6. GitHub, apps, MCP OAuth, cmux account (signin-github-setup-ux)

To be written by `signin-github-setup-ux`: the GitHub install and redirect, the styled "you're
signed in, back to cmux" page on our domain for every callback (3+ variants), Settings >
Connections and MCP OAuth (Linear, Slack, Sentry), and cmux's own account (passkeys, the magic
link handled in-app).
