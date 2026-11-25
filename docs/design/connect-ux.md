# Connect UX: every sign-in, one pattern

Status: decided 2026-11-25 (interim-coord: one design, one card component, one doc shared by two
lanes). Ask trace: `ask-d45cba766c`.

Leo, 2026-11-25:

> btw actually on the whole claude setup situation what about other ones? chatgpt? are there deeper
> ergo things we can do wrt that? and other apps and whatnot? and also spruce up the signed in to
> github page situation? maybe our auth too?

Owners:

- **cloud-claude-connect-ux**: model providers (Claude, ChatGPT/Codex, Gemini, Cursor, OpenCode, API
  keys). Its rows in the tables below are left for it to fill in.
- **signin-github-setup-ux**: GitHub; other apps (Settings > Connections, MCP OAuth); cmux's own
  account sign-in (passkeys, magic link in-app, the signed-in page).

## The pattern (every connection)

1. **An inline card where the need arises.** The connection is asked for where it's missing: a chat
   whose agent hit a 401, a composer that needs GitHub, a Settings row. Every surface uses the same
   `ConnectCard` (`webviews/src/pages/shared/connect/`). It has a provider mark, one line on why, a
   status pill and exactly one primary action.
2. **One click.** The primary action starts the flow. No copy-paste, unless the provider only takes
   an API key; then the card holds the key field itself.
3. **Done in our in-app browser sheet.** The provider's page opens in a cmux browser tab beside the
   pane that asked, never the system browser. That tab has cmux's imported browser sessions, so most
   people are already signed in at the provider.
4. **A styled "you're signed in, back to cmux" page on our own domain for every callback**
   (`https://cmux.com/connected?app=…&status=…`). It is one page with 3+ variants, used by:
   - the cmux account's after-sign-in;
   - the MCP hub's loopback (a 302 to the page);
   - the platform's MCP callback fallback.

   In the in-app tab the page's "Back to cmux" `cmux://` link is handed off in-process with no
   prompt, and the tab closes (`BrowserExternalApps.openOwn`, #55885). In a system browser it is the
   same page with a button.
5. **The app captures the token.** Each kind keeps its token in its own place:
   - platform-sealed (Connections);
   - hub-stored (local MCP);
   - Keychain (cmux account);
   - CLI auth files (harnesses).

   The person never copies a token.
6. **A status pill per connection.** The pill states are:
   - connect
   - waiting
   - connected
   - expiring
   - sign in again
   - unavailable
   - error

   The pill text comes from Rust where the state does (`mcp_servers.rs entry_view`).
7. **Re-auth before expiry.**
   - Refresh tokens refresh silently 60 s early: the hub does this today (`McpHub::headers_for`), and
     the platform design says the same.
   - A connection that can't refresh shows **expiring** with Reconnect before it lapses, not after
     a failed tool call.
8. **One place listing every connection.** Settings > Integrations > Connections opens with an *All
   connections* list. It covers:
   - the cmux account
   - GitHub
   - model accounts
   - apps

   Each row has a pill and one action. Rows owned by another surface link there.
9. **On by default.** The card and the signed-in page ship with 3+ gallery variants each, and the
   best one is the default arm.

## Today, mapped (2026-11-25, feat-cmux-next 1a1723eeab3)

| Flow | Where it opens | Token back | Landing page | Pill |
|---|---|---|---|---|
| Settings > Connections (Linear, Sentry, Notion, …) | System browser (`SettingsConnections.swift`, `LinkRouter.open(.system)`) | Platform seals it; app polls 2 s × 60 s | Platform redirect to `cmux://settings/integrations` (browser prompt "Open cmux?") | Yes (Rust labels) |
| Settings > MCP Servers (local hub OAuth 2.1, DCR, PKCE) | In-app tab (`openWeb`) | Hub loopback `127.0.0.1:<port>/callback` | Inline HTML on the loopback (`oauth.rs auth_page`), not our domain; tab stays open | Yes |
| Agent asks for an MCP server (`_acpmux/mcp_connect_request`) | n/a | n/a | n/a | The chat card for `needs_auth` is unbuilt |
| cmux account: email code ("magic link") | `ASWebAuthenticationSession` popup (Safari) or the default browser | `cmux://auth-callback` + state nonce | Plain white HTML (`after-sign-in/handler.ts nativeReturnResponse`) or a bare 302 | Accounts row |
| cmux account: passkey | Same; web page only (`PasskeyButton`) | Same | Same | Same |
| cmux account: GitHub / Google / Apple | Same | Same | Same | Same |

## Step counts

The table counts what the person does: clicks, typing, app switches and browser prompts. The provider
page's own sign-in is left out when the person is already signed in there. "Hops" counts windows
outside cmux.

| Provider / flow | Before: steps | Before: hops | After: steps | After: hops | What removes the steps |
|---|---|---|---|---|---|
| Linear, Sentry, Notion, Stripe, Vercel, … (Settings > Connections) | 5: open Settings > Integrations, Connect, Approve, "Open cmux?" Allow, switch back | 1 browser | 2: Connect, Approve | 0 | In-app sheet; `cmux://settings/integrations` handed off in-process; tab closes; pill flips |
| Same, asked for in a chat | 7: notice the error, open Settings, find the app, then the 4 above | 1 | 2: Connect on the inline card, Approve | 0 | Inline `ConnectCard` where the 401 happens |
| Slack (Connections) | Hidden here; goes through the integrations hub provider | 1 | 2 | 0 | Same card once the platform client is registered ([outward]) |
| MCP server via local hub (Settings > MCP Servers) | 4: Sign In, Approve, close the loopback tab, go back | 0 (in-app tab) | 2: Sign In, Approve | 0 | Loopback 302s to `cmux.com/connected`, which hands back and closes |
| API-key apps (Context7, Exa) | 3: Connect, paste key, Save | 0 | 2: paste key, Connect | 0 | Key field in the card |
| cmux account: email code | 7: Sign in, email + Continue, switch to Mail, read the code, type it, "Open cmux?" Allow, switch back | 1 browser + Mail | 4: Sign in, email + Continue, read the code in Mail, type it | 0 browser | In-app sheet; callback handed off in-process; tab closes |
| cmux account: emailed link clicked | 6: click the link in Mail, browser opens, sign-in finishes there, "Open cmux?" Allow, switch back, (state lost: may need to start over) | 1 | Target 2: click the link, "Finish in cmux" | 1 | Link-to-app handoff (see Open questions) |
| cmux account: passkey | 5: Sign in, Passkey, Touch ID, "Open cmux?" Allow, switch back | 1 | 3: Sign in, Passkey, Touch ID | 0 | In-app sheet (CEF WebAuthn on cmux.com) |
| cmux account: GitHub / Google / Apple | 5: Sign in, Continue with X, Authorize, "Open cmux?" Allow, switch back | 1 | 3: Sign in, Continue with X, Authorize | 0 | In-app sheet with imported sessions |
| GitHub (repo access) | Owned by the GitHub helpers (#55885) | | | | |
| Claude | *cloud-claude-connect-ux* | | | | |
| ChatGPT / Codex | *cloud-claude-connect-ux* | | | | |
| Gemini | *cloud-claude-connect-ux* | | | | |
| Cursor | *cloud-claude-connect-ux* | | | | |
| OpenCode | *cloud-claude-connect-ux* | | | | |
| API keys (Anthropic, OpenAI, …) | *cloud-claude-connect-ux* | | | | |

## Shared pieces

- **`ConnectCard`** (`webviews/src/pages/shared/connect/ConnectCard.tsx`):
  - Provider-agnostic props: provider id, title, icon, why line, state, one primary action, an
    optional secondary action behind an inline confirm, and an optional key field.
  - The model-provider lane renders its Claude and ChatGPT cards with it, so they share one look and
    one pill vocabulary.
  - Its variants are a `defineExperiment` registered in `webviews/src/experiments/registry.ts`, on by
    default.
- **Signed-in page** (`web/app/connected`):
  - Params:
    - `app`: from an allowlist of known ids; anything else shows a generic page.
    - `status`: `ok` or `error`.
    - `return`: only `cmux`, `cmux-nightly` or `cmux-dev`.
    - `variant`: 3+ looks.
  - Every value is allowlisted, so there is no open redirect and no reflected markup.
  - It is localized in every `web/messages` locale and needs no external fonts.
  - The cmux account's after-sign-in page uses the same look.
- **In-app hand-back**: #55885 `BrowserExternalApps.openOwn`.
  - An own-scheme link that ends a flow cmux started is routed in-process with no prompt, and the
    flow's tab closes.
  - Connections returns (`settings/integrations`, `settings/connections`) join the sign-in callback
    and the GitHub completion as handoffs.
- **Where it opens** (Rust `cmux-cloud-config`):
  - `SignInWindow` gains an in-app place, and `automatic` now picks the in-app sheet.
  - The popup and default-browser places stay as Debug choices, and "Continue in browser" stays as
    the way out.

## Deeper ergonomics (beyond one click)

- **Ask where it breaks.** An agent's 401 or `needs_auth` becomes the inline card in that chat, so
  nobody hunts through Settings.
- **Already signed in.** The in-app sheet runs on the cmux browser profile with imported sessions
  (`CmuxNextCookieImport`). The provider's page is usually just Authorize.
- **Never expire silently.** Tokens refresh 60 s early. One that can't refresh turns the pill to
  *expiring* while it still works, so Reconnect happens before a tool call fails.
- **Detect, don't ask.** Logins that already exist on disk (`gh`, `claude`, `codex` auth files)
  show as connected, with no flow at all. The model-provider lane owns the harness side of this.
- **Passkey first.** On a Mac with a cmux passkey, the in-app sign-in is three steps with no typing.

## Open questions and follow-ups

- **Emailed link clicked outside cmux.**
  - Stack's link finishes the sign-in in whichever browser Mail opens, and the native state nonce
    is bound to the attempt cmux started.
  - The fix is a "Finish in cmux" handoff: `cmux://auth-magic?code=…`, completed by the in-app
    sheet. That needs web and app work, plus a trust review of a code arriving by URL.
  - Until then, the emailed code typed in the sheet is the in-app path.
- **iCloud Keychain passkeys in CEF.**
  - Chromium's macOS platform authenticator wants the browser public-key-credential entitlement.
    Nightly and release have it; tagged dev builds don't.
  - Profile passkeys work everywhere.
- **Platform expiry field.**
  - The connections catalog needs each connection's `expiresAt`, or a computed `expiring` state, for
    the pill to warn early.
  - The platform design refreshes 60 s early, but it doesn't expose expiry to the app yet.
- **Slack, Google and Figma** need registered OAuth clients ([outward] in
  `docs/design/integrations.md`).

## PRs

Filled in as they open:

- Doc, `ConnectCard`, pills and the All connections list: lane/connections-signin
- Signed-in page on cmux.com for every callback: lane/connections-signin-page
- In-app cmux sign-in (passkeys, emailed code) and Connections in-app: lane/connections-signin-inapp
- Model providers: cloud-claude-connect-ux
