# GitHub setup handoffs: composer picker, cmux Cloud and the cmux GitHub App

Leo, 2026-11-25: "there are illogical situations that happen with when you're setting up your github repos and
such in the composer picker area and our cmux cloud/cmux github app and it says it wants to open it in the cmux
app but if you're using the cmux browser to do that then it should already know etc"

This walks every path from the composer's Add project picker (GitHub repository step) through GitHub's App pages
and back, names each step that does not follow, and marks what this PR fixes. Line numbers are at this PR's head.

## The pieces

- Picker: `webviews/src/agent-session/acpmux/SourcePicker.tsx`, `sourcePickerModel.ts`, `githubRepos.ts`,
  `FolderPopover.tsx`. Connect sends `github.connect` to the host and waits for `cmux-github-changed` or the page
  becoming key again.
- Host: `Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/AgentPaneGitHubRequest.swift:88` (needs a gesture,
  opens the install page or the cmux sign-in), `CmuxNextAccounts/GitHubConnections.swift:92` (the API's
  `integration.connect`, with an optional repository).
- Flow tab: GitHub's pages open where link routing says. `CmuxNextSettings/SignInPage.swift:33` (`init?(url:)`) decides which
  pages are sign-in pages that always open in a cmux tab.
- Return: GitHub redirects to the console's `/integrations/callback`
  (`backend/apps/dashboard/src/routes/integrations/callback.tsx`), which 302s an app-started connect to the app's
  own `<scheme>://integration/complete` link. `CmuxNextApp/AppDelegate.swift:557` finishes it
  (`CloudGitHubCompletion`).
- Own-scheme links inside a cmux tab: `CmuxNextBrowser/Core/BrowserExternalApps.swift`.

## Paths

### 1. In the cmux browser (any of the paths below, when the flow tab is a cmux tab)

1. Connect to GitHub, the install page opens in a cmux tab, the person picks repositories and saves.
2. GitHub redirects to the console callback, which 302s to `cmux://integration/complete?...`.
3. Before: the cmux tab treated cmux's own scheme like any other app: it asked "Open cmux?"
   (`BrowserExternalApps.swift:126`, `.openExternalApp`), and on Allow it handed the link to Launch Services,
   which could open a different cmux build (stable or a dev build) that has no such pending connect. This is the
   illogical step Leo named. **Fixed:** the app's own schemes (`CFBundleURLSchemes`,
   `BrowserExternalApps.swift` `schemes(in:)`) are routed in-process (`openOwn`, `BrowserExternalApps.swift:78`).
   A handoff (the GitHub completion link or the auth callback, decided by the app at `AppDelegate.swift:308`)
   opens with no prompt. Any other own-scheme link still asks, and on Allow routes in-process, never to another build.
4. Before: the flow tab stayed open on the console's fallback page, and focus stayed on it, not on the pane that
   started the connect. **Fixed:** after a handoff the tab closes when its first page was a sign-in or install
   page (`AppDelegate.swift:311`), and the link opener returns focus to the pane that opened it. A tab the person
   was already using stays open.

### 2. No app installed

1. Picker, GitHub step: "Connect to GitHub". Host opens GitHub's install page (`/apps/<app>/installations/new`).
2. Before: that page was not a sign-in page (`SignInPage.swift` matched OAuth `authorize` only), so with links
   going to the system browser it opened in Chrome. Its return then always went through "Open cmux?"
   in Chrome. **Fixed:** GitHub App install and configure pages (`/apps/<app>/installations/new`,
   `/select_target`, `/settings/installations/<id>`, `/organizations/<org>/settings/installations/<id>`) are
   sign-in pages (`SignInPage.swift:52`), routed like the OAuth authorize page, so the whole flow stays in cmux
   and path 1 applies.
3. Before: a repository the person typed (or the folder's `github:` repo) was forgotten. After the install they
   had to find and pick it again. **Fixed:** Connect remembers it (`githubRepos.ts:330`), sends it to the host so
   GitHub's page opens for its owner, and after `cmux-github-changed` picks it if it is listed (`settleWanted`,
   `githubRepos.ts:232`; `FolderPopover.tsx:97`). It searches once when the list is truncated.

### 3. App installed, repository not granted

1. Picker lists the granted repositories. The person types `acme/billing`.
2. Before: "No repositories found", with nothing saying the repository exists but is not shared, or what to
   do. **Fixed:** an `owner/name` with no match says "acme/billing isn't shared with cmux yet. Add it on GitHub
   with the option above." (`SourcePicker.tsx:492`). Choose more repositories... opens GitHub with that
   repository (`SourcePicker.tsx:497`).
3. Before: after saving on GitHub's configure page, nothing said whether it worked. **Fixed:** the picker picks
   the repository when it shows up. If it still isn't there, the step says it isn't shared
   (`SourcePicker.tsx:494`).

### 4. Organization approval pending

1. A member installs on an org. GitHub sends an approval request (`setup_action=request`).
2. Before: the step said "An organization owner needs to approve the installation." with Connect to GitHub
   under it, and no word on what happens next. **Fixed:** "An organization owner needs to approve cmux. Once they
   do, your repositories show up here." (`sourcePickerModel.ts:34`). The status is re-read on
   `cmux-github-changed` and when the page becomes key, so the list appears after approval.
3. Console callback for a request: says the request went to the owners (`OWNER_REQUEST_MESSAGE`). Unchanged; it
   reads correctly.

### 5. Signed out of cmux

1. Picker row says "Sign in". Pressing it opens the cmux sign-in (`AgentPaneGitHubRequest.swift:91`).
2. **Not fixed:** after signing in, the person has to press Connect to GitHub again. The host needs a fresh
   gesture to open GitHub (`AgentPaneGitHubRequest.swift:89`, `gestureRequired`), and a sign-in completion is
   not one. A follow-up needs the host to carry the pending connect across sign-in.
3. Console side: a connect started from the console while signed out of the console. Before: "Sign in as the
   person who started this connection, then open the link again." There was no link to open again (GitHub's
   redirect is one-time), so it was a dead end. **Fixed:** "Sign in to cmux" saves the callback (state, code,
   installation_id, setup_action, error only; `backend/apps/dashboard/src/lib/return-path.ts`). Sign-in comes
   back to it and finishes the connection (`callback.tsx:113`).

### 6. Signed out of GitHub

1. The install page sends the person to `github.com/login?return_to=...`. That is a sign-in page (last segment
   `login`), so it is in a cmux tab, where passkeys and saved passwords work. GitHub then continues to the
   install page, which is now also a cmux tab (path 2), and the return follows path 1. Nothing illogical is left
   once paths 1 and 2 are fixed.

### 7. In Chrome or the system browser

Reached only when the person's link routing sends GitHub to another browser, since install pages now default
to a cmux tab (path 2).
1. Chrome asks "Open cmux?" for the completion link. That is correct there: Chrome cannot know.
2. Before: the console fallback said "Open cmux to finish connecting GitHub." for every provider, including
   Linear and Slack, and did not say the page could be closed. **Fixed:** "Finishing the connection in cmux. If
   cmux didn't open, open cmux. You can close this page after." (`callback.tsx:95`).

## Not walked live

The lane VM is Linux with no GitHub token, no cmux app and no Swift toolchain, so none of the paths above were
clicked through end to end against GitHub. Each step was read from the code and covered by a test at the boundary:
- Swift: `BrowserExternalAppConsentTests`, `SignInPageRoutingTests`. These compiled through `cmux-ci compile-check`,
  and run in PR CI.
- Webviews: `composer-github-folders.test.tsx`.
- Dashboard: `return-path.test.ts`, `integration-callback-route.test.ts`.

Organization approval (path 4) needs a second GitHub account that owns an org. Signed out of GitHub (path 6)
needs a browser profile without a GitHub session. Both are left for a NIGHTLY walk with `cmux app try <PR>`.
