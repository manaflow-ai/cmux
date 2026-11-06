# Apple notary status 7000: support request draft (cx-f58x)

Status: draft, not sent. A person on the Apple Developer account (team
7WLXT3NR37) files it; agents never send it.

## Where to file

1. Sign in at https://developer.apple.com/contact/topic/select with an
   Account Holder or Admin Apple ID of team 7WLXT3NR37.
2. Pick **Development and Technical** > **Notarization** (if that topic is
   absent: **Membership and Account** > **Other Membership and Account
   Questions**).
3. Paste the text below. Attach the two notary logs
   (`xcrun notarytool log <submission-id>` for `de5255b1…` and `52c6c12d…`;
   the full ids are in the nightly run summaries of 2026-10-07/09).

## Request text

Subject: Notarization returns status 7000 for one build of our app, Accepted for the same commit without browser-import code

Hello,

Our team (Team ID 7WLXT3NR37) notarizes the macOS app
"cmux" (bundle IDs com.cmuxterm.app.nightly and com.cmuxterm.app.next,
Developer ID Application, hardened runtime) every night with notarytool and
an App Store Connect API key.

Since 2026-10-07 12:34 UTC every submission of our nightly build that
contains our browser-import feature ends with status code 7000 ("Team is not
yet configured for notarization"). In October we submitted two builds of
the same source commit, signed with the same certificate and entitlements:

- submission de5255b1… (feature included): status 7000, Invalid
- submission 52c6c12d… (feature compiled out): Accepted

Our team has notarized builds for months, and builds without the feature are
still Accepted every night, so the team is configured. We believe the
service holds the build because of what the feature does, and we want to
know what you need from us to have it reviewed.

What the feature does: when the user clicks "Import" in the app and picks a
browser profile (Chrome, Helium, Arc, Brave, Edge, Firefox, Safari, and
others), the app reads that profile's bookmarks, history, open tabs, cookies
and saved passwords on this Mac and copies them into the app's own built-in
browser profile, so the user can switch browsers without signing in again.
It is the same function as Safari's, Chrome's and Arc's "Import from another
browser". To decrypt Chromium cookies and passwords it asks the macOS
Keychain for the browser's "Safe Storage" item, which shows the system
Keychain consent prompt; the user must click Allow. Firefox data is read only
from the profile folder the user grants (Full Disk Access or an open panel).
Nothing is read before the user's click, and nothing leaves the Mac: the data
goes only into the app's local profile.

Questions:
1. Is status 7000 on these submissions a hold on our team or on this
   binary's content, and can you review it?
2. Is there a review or entitlement path for a browser that imports other
   browsers' data (as other notarized browsers such as Arc and Brave do)?
3. If a part of the binary triggers it, which part, so that we can change it?

We can send a build, source excerpts, or a screen recording of the import
flow. Thank you.

[Name of the account holder], [company name as on the developer account]
