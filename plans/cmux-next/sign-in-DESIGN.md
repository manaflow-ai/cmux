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

GitHub's install and redirect belong to the GitHub helpers (#55885: `BrowserExternalApps.openOwn`
hands an own-scheme return from a cmux tab to the app in-process, with no prompt, and closes the
flow's tab). Everything below builds on that.

### 6.1 Today, mapped (feat-cmux-next 1a1723eeab3, 2026-11-25)

| Flow | Opens in | Token back | Landing page | Pill |
|---|---|---|---|---|
| Settings > Connections (Linear, Sentry, Notion, Stripe, …) | System browser (`SettingsConnections.swift`, `LinkRouter.open(.system)`) | Platform seals it; app polls 2 s × 60 s | Platform redirect to `cmux://settings/integrations` behind the browser's "Open cmux?" | Yes (labels from Rust `mcp_servers.rs entry_view`) |
| Settings > MCP Servers (local hub OAuth 2.1, DCR, PKCE) | In-app tab | Hub loopback `127.0.0.1:<port>/callback` | Inline HTML on the loopback (`oauth.rs auth_page`), not our domain; tab left open | Yes |
| Agent asks for an MCP server (`_acpmux/mcp_connect_request`) | n/a | n/a | n/a | No inline `needs_auth` card yet |
| cmux account: emailed code, passkey, GitHub/Google/Apple | `ASWebAuthenticationSession` popup (Safari) or the default browser | `cmux://auth-callback` + state nonce | Plain white HTML (`after-sign-in/handler.ts nativeReturnResponse`) or a bare 302 | Accounts row |

### 6.2 Steps before and after

Steps are the person's clicks, typing, app switches and browser prompts; a provider page's own
sign-in is left out when already signed in there. Hops are windows outside cmux.

| Flow | Before | After | What removes the steps |
|---|---|---|---|
| Linear, Sentry, Notion, … from Settings > Connections | 5 (open Integrations, Connect, Approve, "Open cmux?" Allow, switch back), 1 hop | 2 (Connect, Approve), 0 hops | In-app sheet; `cmux://settings/integrations` handed off in-process; tab closes; pill flips |
| Same, needed in a chat | 7 (notice, open Settings, find it, then the 4 above) | 2 (Connect on the inline card, Approve) | Inline card where the 401 happens (next) |
| MCP server via the local hub | 4 (Sign In, Approve, close the loopback tab, go back) | 2 (Sign In, Approve) | Loopback 302s to `cmux.com/connected`, which opens cmux |
| API-key apps (Context7, Exa) | 3 (Connect, paste, Save) | 2 (paste, Connect) | Key field in the card |
| cmux account: emailed code | 7 (Sign in, email + Continue, switch to Mail, read code, type it, "Open cmux?" Allow, switch back), browser + Mail | 4 (Sign in, email + Continue, read code in Mail, type it), 0 browser hops | In-app sheet; callback handed off in-process; tab closes |
| cmux account: emailed link clicked in Mail | 6, and the native attempt's state is lost | target 2 ("Finish in cmux") | Link-to-app handoff (open, 6.5) |
| cmux account: passkey | 5 (Sign in, Passkey, Touch ID, "Open cmux?" Allow, switch back) | 3 (Sign in, Passkey, Touch ID) | In-app sheet (CEF WebAuthn on cmux.com) |
| cmux account: GitHub / Google / Apple | 5 | 3 | In-app sheet with the profile's sessions |

### 6.3 The signed-in page, on our domain, for every callback

`https://cmux.com/connected?app=<id>&status=ok|error[&return=<scheme>][&variant=card|plain|spotlight]`
(`web/app/connected`). Every value is allowlisted (`apps.ts`, own schemes only), so it is no open
redirect and reflects no markup; dark and light; system fonts only; every `web/messages` locale.
"Back to cmux" opens the app once on success; in a cmux tab that link is an in-process handoff and
the tab closes. Used by the cmux account's after-sign-in page (same look), the local hub's loopback
(302 on success; errors keep the inline page so error text never enters a URL), and the platform's
MCP callback fallback. Three looks; `card` is the default.

### 6.4 Where it opens, the pills, one list

- Rust `cmux-cloud-config` decides where the cmux sign-in opens; `automatic` is now the in-app sheet,
  the popup and default browser stay as Debug choices, "Continue in browser" stays as the way out.
- Settings > Connections Connect/Reconnect open the vendor page in the in-app sheet; the platform's
  return link is a handoff.
- App connections render on section 2's card with a status pill (connect, waiting, connected,
  expiring, sign in again, unavailable, error); labels come from Rust where the state does.
- Settings > Integrations > Connections opens with *All connections*: the cmux account, GitHub, model
  accounts and apps, each with a pill and one action; rows another surface owns link there.

### 6.5 Open

- **Emailed link clicked outside cmux.** Stack finishes it in whatever browser Mail opens, away from
  the attempt cmux started. Fix: a "Finish in cmux" handoff the in-app sheet completes, after a
  trust review of a code arriving by URL. Until then the emailed code typed in the sheet is the path.
- **iCloud Keychain passkeys in CEF** need the browser public-key-credential entitlement (nightly and
  release have it; tagged dev builds do not). Profile passkeys work everywhere.
- **Expiry.** The platform catalog needs each connection's `expiresAt` (or a computed `expiring`
  state) for the pill to warn before a token lapses; it refreshes 60 s early but does not say so yet.
- **Slack, Google, Figma** need registered OAuth clients (`docs/design/integrations.md` [outward]).
- **Inline `needs_auth` card in chat** for an agent's MCP 401 (integrations slice 3).
