# Email verification AutoFill (cmux-next browser)

Request (u2244): when a site says "we sent a verification email" (or a code),
cmux shows a small banner on that page with the code, or one button that
opens the verification link. Opt-in. Like Apple's Security Code AutoFill.

Request 2 (Lawrence, 2026-11-15, msg 34418, a Slack "We emailed you a code"
screen with six boxes): "the macOS thing for iMessage where it fills in
codes, but for email, opt in, smartly and securely."

Status: slices 1 and 2 shipped behind `browser.verificationAutofill.enabled`
(off). Slice 2 wires Mail.app (the first source), the page detector, and
Fill Code / Open Link in WebKit and Chromium tabs. Decisions (2026-10-19):
Mail.app first; brands that mail from another domain fail closed; the bar
shows the code. The Settings row (Browser > Passwords) is shown; the
switch stays off by default.

Slice 3 (2026-11-15, this request) adds:

- **Gmail in cmux's browser** as the second source, the one that works for
  the person today (no Mail.app accounts on their Mac; their mail is a
  Google Workspace account they use in the browser). See "Email sources".
- **Per-account opt-in**: `browser.verificationAutofill.accounts`, the
  addresses the person turns on one by one. Turning `enabled` on alone reads
  no mail.
- **The suggestion at the field**: "Fill code 482 913 / From slack.com" in a
  native card under the code field, like macOS's "From Messages" row, with
  Down Arrow then Return, or a click. The prompt bar stays the fallback
  (no field found) and the home of link offers.
- **Detection** of rows of one-character boxes (Slack's 3-3) and "we
  emailed you a code" wording.
- **Extraction** of `Q7K-2PL` / `KPD-XMF` style codes, Google's `G-` prefix,
  and code words in 20 languages, proven on a corpus.
- **A reviewed sender map**: codes for chatgpt.com from openai.com, for
  login.live.com from microsoft.com, and a few more (exact registrable
  domains of one owner). Links still need the page's own site.
- Agents: an offer an agent's tab took after it showed fills nothing; the
  debug socket cannot accept an offer.

## What Apple and Chrome do

- **Apple (iOS 12+, macOS Sonoma+ for Mail):** Messages and Mail detect a
  one-time code in a new message. Safari shows it in the QuickType bar or
  the AutoFill menu of a field marked `autocomplete="one-time-code"` (or a
  field it guesses is a code field). The page does not see the code until
  the person taps it. "Delete after use" removes the message. Apple does
  not bind ordinary codes to a site: any page with a code field can get the
  offer, so a phishing page can harvest it if the person taps. Apple's fix
  for that is the **origin-bound one-time code** format (WICG
  sms-one-time-codes): the last line `@example.com #123456` binds the code
  to `example.com`, and Safari offers it only there.
- **Chrome:** the WebOTP API (`navigator.credentials.get({otp})`) reads an
  origin-bound SMS on Android only. Chrome desktop has no email code
  AutoFill. Chrome on macOS shows nothing from Mail.

cmux does better than Apple on binding: an email code is offered only on a
page of the **same site as the sender**, never on every code field.

## Email sources (where an email comes from)

Every source sits behind `VerificationEmailSource`
(`emails(receivedSince:accounts:)`, `availableAccounts()`); the app reads all
of them through `CombinedVerificationSource`, only while a page waits, only
for opted-in accounts, only mail received since the wait started.

| Source | Access it needs | Setup for the person | Sender + auth | Verdict |
|---|---|---|---|---|
| **Gmail in cmux's browser** (Gmail's inbox feed, `mail.google.com/mail/u/N/feed/atom`) | The Google sign-in already in the cmux browser profile. The request runs inside Chromium's network stack in the waiting page's profile (`cmux_shim_profile_fetch`, a `CefURLRequest` in that request context), so no cookie leaves Chromium. The feed holds unread inbox mail only: subject, a ~100-character snippet, From address, time. | None, if they use Gmail in cmux (add the address in Settings). | From address from Google's own feed (not page content); no DKIM result (Gmail already spam-filters the inbox). | **Shipped (slice 3), first for this person.** Google documents the feed for Workspace accounts (developers.google.com/workspace/gmail/gmail_inbox_feed, 2026-04); personal accounts may answer it too. |
| Mail.app via Apple Events | One Automation prompt ("cmux wants to control Mail"). | Accounts set up in Mail. | `sender`, `all headers` (DKIM/DMARC aligned). | **Shipped (slice 2)**, now per account. |
| Gmail API, read-only scope, the person's own OAuth sign-in | `gmail.readonly` (or `gmail.metadata`) is a *restricted* scope: a public app needs Google's verification and a yearly third-party security assessment (CASA), paid. | A Google consent screen. | Full headers. | **Later.** Needs a Google Cloud OAuth client cmux does not have, and money. A Workspace admin can allow an internal client for their own domain without that review. |
| Microsoft Graph `Mail.Read` (Outlook, Microsoft 365) | An Entra app registration (free); some tenants need admin consent. | A Microsoft consent screen. | Full headers. | **Later.** No client exists yet; same interface. |
| Reading a signed-in webmail tab's page (DOM) | Script in the Gmail/Outlook page. | Keep the tab open. | Display names and page text that any mail can shape. | **Refused.** Fragile, and the page's own script controls what it shows. |
| macOS notifications of other apps | Full Disk Access or Accessibility. | Big permission. | No address. | **Refused.** |
| IMAP with an app password | cmux would store a mail credential. | Make and paste an app password. | Yes. | **Not now.** |

Why the feed and not the API first: it reads less (unread inbox snippets,
not every message), needs no new credential, no OAuth client, no Google
review, and nothing stored in the Keychain; its cost is that it depends on a
Google-documented but old endpoint, and gives no DKIM verdict (so it offers
codes, never links). The cookies replay risk is avoided by fetching inside
Chromium: replaying Google session cookies from another HTTP client could
trip Google's device-bound session checks and sign the person out.

Keychain: no source stores a token today. An OAuth source (Gmail API,
Graph) keeps its refresh token in the Keychain, never in cmux.json.

## Page signal (when a page waits for an email)

A tab waits for a verification email when its top frame, on an `https`
page, shows at least one of:

1. a field with `autocomplete="one-time-code"`;
2. a row of 4 to 8 visible one-character fields (Slack's 3-3 boxes, most
   six-box code screens);
3. visible text that says a code or link was sent ("we sent", "we emailed
   you a code", "check your email", "enter the 6-digit code", "confirmation
   code", "magic link", ...; English for now).

Only then does cmux look for mail.

The signal records the tab, the page's origin, and the time it started. It
ends when the tab navigates to another site, closes, or 10 minutes pass.
Subframes never raise a signal (an ad iframe cannot ask for codes).

## Matching (`VerificationOfferPolicy`)

An email becomes an offer on a waiting tab only when every rule holds:

1. **Feature on.** `browser.verificationAutofill.enabled` is true (off by
   default).
2. **Tab is a person's tab.** Agent-driven tabs never get offers (same rule
   as `PasswordFillPolicy`: an agent's click would release the code to page
   script).
3. **Secure page.** The page is `https` (or `http://localhost` for
   development builds only, not in slice 1).
4. **Same site.** The registrable domain (eTLD+1, full Public Suffix List)
   of the sender's address equals the page host's registrable domain, or
   both are in one group of the reviewed sender map
   (`VerificationSenderMap.reviewed`: Microsoft, Google/YouTube, Meta,
   OpenAI/ChatGPT, Anthropic/Claude, X/Twitter, Steam, Apple; exact
   registrable domains only, so a lookalike is in no group). A mapped
   sender gets a code offer only, never a link.
   `noreply@accounts.github.com` matches `github.com`; it never matches
   `github.com.evil.io`, `evil-github.com`, or `someone.github.io` (a
   public suffix). If the email has an origin-bound line
   (`@example.com #123456`), the page host must be that exact host, and
   that rule replaces the sender rule for the code.
5. **Time window.** The email arrived no earlier than 60 s before the signal
   started and no later than 10 min after, and is less than 10 min old now.
   The 60 s before is kept on purpose (the request asked for "after the page
   asked"): the arrival time is the mail server's clock, and the page
   reports up to a second after its code screen shows, while fast senders
   deliver in a second or two. Without it, a real code is lost.
6. **Opted-in account.** The mail was delivered to an address in
   `browser.verificationAutofill.accounts`; a source reads no other account,
   and the coordinator drops mail with no known account.
7. **One clear answer.** The parser finds exactly one code, or exactly one
   same-site verification link. Two different codes, or two different
   candidate links, give no offer (no guessing).
8. **Links are same-site and safe.** `https` only, no user info
   (`user@host`), no non-default port, host's registrable domain equals the
   page's. A link needs an authenticated sender (DKIM pass aligned with the
   From domain) when the source can tell; a code does not (a spoofed code is
   only a wrong code; a spoofed link could start an attacker's flow).
9. **Single use.** An email gives at most one offer, once. Fill, Open, or
   Not Now consumes it; it is never shown again.

## Delivery (what the person sees)

**A code offer shows under its field** (slice 3) in its own small window, the
way macOS shows a code from Messages under a field: a borderless child window
of the browser window in the native popup style (the page menus' glass and
the one popup shadow), placed under the field, or above it when the screen
has no room below. One row: an envelope glyph, "Fill code 482 913" over
"From slack.com" (the sender's registrable domain, never a display name).
Page script cannot read, style or click it, and it never takes the keys: the
page keeps typing. The code is grouped for reading (3+3, 4+4). A click
outside the page, the window moving or the app going inactive closes it, and
the offer goes back to the prompt bar, still open.

Why native, not a web-floating surface (design/surface-materials.md lists it
as a `native-overlay`, beside the prompt bar it moves out of): a code must
reach no web content before the person accepts it, and a shared web surface
is one more renderer and IPC path that would hold it.

- **Accept:** a click on the card, or Down Arrow (selects it, a Return hint
  shows) then Return. Escape declines (Not Now); the prompt bar's Not Now does too.
  The keys are the person's own AppKit key presses, read by an event
  monitor only while the card shows and its tab has the keyboard; other
  keys pass to the page. Automation input (CDP, `cmux browser`) is not an
  AppKit event, and agent tabs get no offer anyway.
- **Placement:** an isolated-world script (geometry only, it takes no
  argument and can carry no code) gives the field's rect (the box row
  first to last, else the one-time-code field, else the focused or only
  empty field) as viewport fractions; the card sits under it, or above it
  near the page bottom, and follows it on scrolls and key presses (measured
  again on those events, no timer).
- **No field found**, or the field scrolls away: the offer stays in the
  tab's prompt bar, as in slice 2.
- **Fill** types the code into the field of the top frame (split over the
  boxes when the page uses one-character boxes), only when the tab still
  shows the same site and no agent took the tab. It never presses Enter or
  submits.
- **Link offers** stay in the prompt bar (Open Link, Not Now).

## Threat model

| Threat | Defense |
|---|---|
| Phishing page `evil.com` asks for the bank's code while it drives the real sign-in | Same-site rule: the bank's email never matches `evil.com`. Lookalikes (`bank-secure.com`, `bank.com.evil.io`) fail the eTLD+1 check. |
| Attacker content on a shared host (`someone.github.io`) | Full Public Suffix List, including its private section: `github.io` is a suffix, so `someone.github.io` is its own site. |
| User content on the same registrable domain (e.g. a page builder under the brand's domain) | Residual risk. Mitigations: top frame only, https only, the person must click, origin-bound codes are exact-host. Listed as an open question (allowlist of hosts per brand). |
| Cross-site leakage through the UI | The offer lives in native chrome, not the DOM. No JS API exposes it. Offers are per tab and per origin. |
| Notification or sender spoofing | Display names are never trusted; only an address from a real mail source. Links need DKIM pass when the source gives headers. |
| Navigation race (page moves to another site between offer and click) | The fill and the open check the tab's current origin at click time, and drop the offer if it changed. |
| Codes at rest | Never on disk: no cache, no log line, no crash report field (`VerificationOffer` has a redacted description). Offers expire after 10 min, clear on use, on tab close, on navigation to another site, and when the setting turns off. |
| Auto-submit | Never. The person clicks Fill, then submits. |
| Agents | Agent-driven tabs get no offers; a tab an agent takes after the offer showed fills nothing on accept; no socket, CLI, MCP or automation call lists or answers an offer (the dialog broker skips it, the debug prompt call refuses it, every description is redacted); agents cannot read or change either setting (privacy refusal, like passwords). |
| Page JavaScript before the person accepts | The code exists only in Swift memory and the native card; the only scripts run before the click read the page's text or geometry and carry no code. |
| Cross-origin iframes | The detector, the anchor script and the fill run in the top frame only; a subframe never raises a wait or receives a code. (A same-origin frame's field is not filled either: slice 3 keeps it top-frame only.) |
| Gmail session misuse | The feed request runs inside Chromium in the waiting page's profile, `https` only, no redirects followed, no auth prompt answered, body capped at 512 KB; cookies never reach Swift, a page, or another HTTP client. |
| Another person's mail | Per-account opt-in: only listed addresses are read; the Gmail source reads only the feed title of other signed-in slots to find the listed ones. |
| Mail content exposure to cmux | Sources read only messages received in the window, only while a page waits, and parse in memory. |

## Slice 1

- `PublicSuffixList` (bundled list from publicsuffix.org, MPL-2.0, the same
  data `backend/scripts/update-public-suffix.ts` writes) with
  `registrableDomain(_:)`. The heuristic `SiteDomain` stays for display only.
- `VerificationMessageParser`: codes near a keyword, origin-bound lines,
  same-site link candidates.
- `VerificationOfferPolicy`: the rules above as one pure function with a
  rejection reason for each rule.
- `VerificationInbox`: in-memory offers per tab, expiry, single use.
- `BrowserPromptKind.verificationOffer` and its prompt-bar row.
- Setting `browser.verificationAutofill.enabled` (off) under Browser >
  Passwords. Its row is hidden from the Settings page and palette
  (`hiddenFromSettingsPage`) until a source ships, so nobody sees a switch
  that does nothing; the key works in cmux.json and agents cannot set it.
- Strings in all 21 locales.
- Tests that fail without the code (Swift Testing).

## Not in slice 1

- A real email source (needs a decision: Mail.app first, Gmail later),
  behind a `VerificationEmailSource` seam that reads only while a page
  waits.
- The page-script detector for the page signal in WebKit and CEF.
- Wiring Fill Code to a trusted insert in each engine, and Open Link to a
  same-tab navigation.
- A THIRD_PARTY_LICENSES entry for the bundled Public Suffix List (MPL-2.0;
  the file carries the MPL notice). The notices are composed from
  `scripts/cmux-next/notices/hand-written.md`, which the license review owns.

## Magic links ("tap the button in the email")

Not built further in slice 3 (the slice 2 prompt-bar Open Link stays).
Design for when it is:

- Same rules as codes, stricter: the link's registrable domain must equal
  the page's (no sender map), `https`, no user info, default port, and the
  sender must pass DKIM aligned with From. The Gmail feed has no
  authentication result and no link targets, so it never offers links;
  Mail.app and the API sources do.
- Never fetch the link in the background: it is single-use and may sign in
  a session in another browser. Open it in the waiting tab only on the
  person's click, so the session lands where they asked for it.
- Many magic links carry a code too (Slack, Notion, Linear): prefer the code
  when both exist; it keeps the person on the page they are on.
- A link that points to another site (click tracking: `links.example-esp.com`)
  is not offered; resolving redirects would mean fetching it, which is the
  click. A reviewed list of tracking hosts could unwrap known formats
  without a fetch.

## Open questions

1. Gmail API or Graph client: worth a Google Cloud OAuth client (with
   restricted-scope review, paid) or an Entra app? Only if the feed stops
   working or people outside Gmail ask.
2. Show the code in the card, or mask it until hover? Apple shows it; cmux
   shows it (it is the person's own mail on their own screen).
3. Offer to delete or archive the email after use (Apple's "Delete after
   use")? Needs write access to the mailbox; not with the feed.
4. Languages for the page detector's wording beyond English.
5. Settings: list the found Gmail and Mail accounts with a switch each
   instead of typing the address (needs a Settings page that asks the app
   for `availableAccounts()`).
