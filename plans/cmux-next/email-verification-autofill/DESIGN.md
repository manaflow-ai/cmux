# Email verification AutoFill (cmux-next browser)

Request (u2244): when a site says "we sent a verification email" (or a code),
cmux shows a small banner on that page with the code, or one button that
opens the verification link. Opt-in. Like Apple's Security Code AutoFill.

Status: slices 1 and 2 shipped behind `browser.verificationAutofill.enabled`
(off). Slice 2 wires Mail.app (the first source), the page detector, and
Fill Code / Open Link in WebKit and Chromium tabs. Decisions (2026-10-19):
Mail.app first; brands that mail from another domain fail closed; the bar
shows the code. The Settings row (Browser > Passwords) is shown; the
switch stays off by default.

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

| Source | Gives sender address + auth headers? | Cost to the person | Verdict |
|---|---|---|---|
| macOS notifications of other apps (Mail, Gmail in Chrome) | No. `UNUserNotificationCenter` gives an app only its own notifications. The Notification Center database (`group.com.apple.usernoted`) needs Full Disk Access, is undocumented, and changes each macOS release. Reading it through Accessibility is screen-scraping. | Full Disk Access or Accessibility for cmux | **Refused.** Too much access, fragile, and a notification has no sender address to match. |
| Web notifications from a webmail tab inside cmux (Gmail, Fastmail) | No. The title is the sender's display name, the body is the subject and snippet. No address, no DKIM. | None (cmux already receives them) | **Not for matching.** Display names are free text: "GitHub" can come from anyone. At most a trigger to check a real source sooner. |
| Mail.app via Apple Events (`NSAppleScript`/ScriptingBridge) | Yes: `sender`, `date received`, `all headers` (with `Authentication-Results`). | One Automation permission prompt ("cmux wants to control Mail"). Works only for accounts set up in Mail.app. | **Recommended first real source.** Local, no credentials pass through cmux. |
| Gmail API (OAuth, `gmail.readonly` or `gmail.metadata`+message get) | Yes: full headers, `internalDate`. | Google sign-in and an OAuth client; `gmail.readonly` is a restricted scope (Google verification + security assessment for a public app). | **Later, opt-in.** Needs a Google Cloud OAuth client: a credential and maybe money; ask first. |
| IMAP IDLE with an app password | Yes. | The person types an app password into cmux. | Not now. cmux would store a mail credential. |

A source reads mail **only while a page waits** (see "Page signal"), only
messages received in the window, and only the fields the parser needs. It
stores nothing.

## Page signal (when a page waits for an email)

A tab waits for a verification email when its top frame, on an `https`
page, shows at least one of:

1. a field with `autocomplete="one-time-code"`;
2. visible text that says a code or link was sent ("we sent", "check your
   email", "verification code", "enter the code", "magic link", and the same
   in the 21 UI locales over time; slice 1 has English);
3. a change-password or sign-in form that the site follows with a "check
   your email" step (case 2 covers it).

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
   of the sender's address equals the page host's registrable domain.
   `noreply@accounts.github.com` matches `github.com`; it never matches
   `github.com.evil.io`, `evil-github.com`, or `someone.github.io` (a
   public suffix). If the email has an origin-bound line
   (`@example.com #123456`), the page host must be that exact host, and
   that rule replaces the sender rule for the code.
5. **Time window.** The email arrived no earlier than 60 s before the signal
   started (clock skew, fast senders) and no later than 10 min after, and is
   less than 10 min old now.
6. **One clear answer.** The parser finds exactly one code, or exactly one
   same-site verification link. Two different codes, or two different
   candidate links, give no offer (no guessing).
7. **Links are same-site and safe.** `https` only, no user info
   (`user@host`), no non-default port, host's registrable domain equals the
   page's. A link needs an authenticated sender (DKIM pass aligned with the
   From domain) when the source can tell; a code does not (a spoofed code is
   only a wrong code; a spoofed link could start an attacker's flow).
8. **Single use.** An email gives at most one offer, once. Fill, Open, or
   Not Now consumes it; it is never shown again.

## Delivery (what the person sees)

The offer shows in the tab's **native prompt bar** (the bar that asks to
save passwords), not in the page's DOM. Page script cannot read it, style
it, or click it. The bar says "Verification code from github.com: 123456"
with **Fill Code**, or "Verification link from github.com" with **Open
Link**, and **Not Now**.

- **Fill Code** inserts the code into the focused field of the top frame as
  typed text (a trusted insert, like paste), only when the tab still shows
  the same origin. It never presses Enter or submits.
- **Open Link** navigates this tab to the link. cmux never fetches the link
  in the background (that would consume a one-time link, or sign in a
  session the person does not hold).

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
| Agents | Agent-driven tabs get no offers; agents cannot read or change the setting (privacy refusal, like passwords). |
| Mail content exposure to cmux | Sources read only messages received in the window, only while a page waits, and parse in memory. |

## Slice 1 (this change)

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

## Open questions

1. First source: Mail.app over Apple Events (one Automation prompt, no
   credentials) or Gmail API (Google OAuth client, restricted scope,
   possible verification cost)?
2. Brands whose mail comes from another domain (YouTube codes from
   `google.com`, Slack from `slack.com` for `*.slack.com` workspaces work;
   but e.g. `x.com` from `twitter.com`). Fail closed (now), or ship a small
   reviewed alias table?
3. Show the code in the bar, or mask it until the person hovers? Apple
   shows it.
4. After use, should cmux offer to delete or archive the email (Apple's
   "Delete after use")? That needs write access to the mailbox.
