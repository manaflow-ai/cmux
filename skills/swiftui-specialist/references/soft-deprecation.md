# Soft-Deprecated APIs

SwiftUI has a number of APIs that are "soft deprecated." A soft-deprecated API is marked deprecated in the SDK headers, but with a deprecation version of `100000.0` — a placeholder that suppresses compiler warnings while signaling that the API should no longer be used in new code.

## Scoping rule — read this first

All soft-deprecation guidance in this document is scoped to the code you are directly modifying. If a file contains multiple views and the user's task only involves one of them, the other views are out of scope.

**What to do**: Only discuss the view(s) you edited. Structure your response as: code output, then reasoning about *your changes*. Nothing else.

**What not to do**: Do not mention, flag, comment on, offer to migrate, or ask about soft-deprecated APIs in out-of-scope code. This includes trailing questions like "Would you like me to migrate OtherView to NavigationStack?" — if you didn't edit that view, don't bring it up. The scoping rule takes precedence over any prompt asking for "observations" or "other notes."

**Why**: Mentioning soft-deprecated APIs in code the user did not ask you to change creates noise, distracts from the task, and pressures the user to do unrelated work.

**Example of what NOT to do**: The user asks you to add a button to `SettingsView`. The same file contains `DashboardView` which uses `NavigationView`. Do not write anything like "I noticed DashboardView uses NavigationView, which is soft-deprecated" or "Note on DashboardView: NavigationView is soft-deprecated." Do not mention `DashboardView` at all.

## How to identify soft-deprecated APIs

Check `references/soft-deprecated-apis.md` for a comprehensive list of all known soft-deprecated SwiftUI APIs and their replacements. The file header shows which SDK versions it was generated from.

If you are working with a newer SDK than the versions listed, this list may be incomplete. In that case, also check the `@available` attribute in the SDK headers. A soft-deprecated API has `deprecated: 100000.0`.

## When generating code

Never recommend or generate code that uses a soft-deprecated API. If you are not certain that an API is not soft-deprecated, check the list in `references/soft-deprecated-apis.md` before recommending it. Any API — even one that worked in a prior release — could have been soft-deprecated since then. Do not rely on memory; verify against the list.

## When the user asks to review, refactor, modernize, or clean up code

Point out soft-deprecated APIs in the code the user asked you to review and suggest the modern replacement. Treat this as informational, not urgent — soft-deprecated APIs still compile and work.

## When the user asks to add a feature or fix a bug

If the view you are editing uses a soft-deprecated API, do NOT replace it in your code output. Keep the existing API exactly as it was, and after providing the requested change, add a brief note offering to migrate as a separate step.

If a *different* view in the same file uses a soft-deprecated API, ignore it completely. Do not mention it, do not offer to migrate it, do not ask about it. You are only responsible for the view you were asked to edit.

**Example — view you ARE editing**: The user asks you to add a search bar to a view that uses `NavigationView`. Your code output must still use `NavigationView`. After the code block, write something like: "I noticed this view uses `NavigationView`, which is soft-deprecated. Would you like me to migrate it to `NavigationSplitView` while I'm in this code?"

**Example — view you are NOT editing**: The user asks you to add a search bar to `SearchView`. The same file contains `HomeView` which uses `NavigationView`. Say nothing about `HomeView` or its use of `NavigationView`. Do not write "I also noticed HomeView uses NavigationView." Do not ask "Would you like me to migrate HomeView?"

**Why**: The user asked for a feature, not a refactor. Silently changing APIs they didn't ask about creates unexpected diffs, risks regressions, and makes the change harder to review. Commenting on views they didn't ask about creates noise and pressure to do unrelated work.

## General guidance

- Never introduce new usages of soft-deprecated APIs in code you write from scratch.
- Don't proactively search for or scan for soft-deprecated APIs — only notice them when they appear in code you are directly modifying for the user's request.
