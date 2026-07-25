# CRUCIBLE — Multi-provider AI-usage HUD

**Candidate:** A usage HUD in the cmux sidebar footer (next to the `?` help button) showing
tokens-left / % used / time-to-reset per AI provider account, across rolling 5h + weekly windows,
with a "multi-account usage limits" panel behind a footer menu item. Providers: Claude, Codex,
Grok, Kimi, Gemini.

**Tracked as:** task #1 · Consent gate crossed (Nick: "full").

## Why this glows AND what it changes
- **It changes what Nick can see.** Right now, "how much have I got left, when does it reset?"
  is invisible until an agent hits a wall mid-task. cmux is the one surface that runs *all five*
  agents side by side, so it is uniquely positioned to be the single pane of glass for usage —
  no other tool sees the whole fleet.
- **The hard part is already built.** cmux already maps window → agent → transcript
  (`RestorableAgentKind`, per-surface env injection, hook records). Usage tracking is 100%
  greenfield, but it hangs off machinery that already exists.
- **The spine is proven.** Codex returns a real `{used_percent, reset_at, credits}` object today.
  This is not a "wouldn't it be cool" — one provider is already live end-to-end.

## The spark
If piggyback-freshness holds (cmux reads the token each CLI *already refreshes to disk*, never
refreshing anything itself), the whole feature is **read-only observation of state that already
exists** — no OAuth reimplementation, no footgun, no new attack surface. The HUD becomes a
window onto files and endpoints that are already there.

## The falsifier (what would prove this is slag)
**If the CLIs refresh their tokens in memory only and do NOT persist the fresh token to a
readable location, piggyback-freshness is impossible** — cmux would see a permanently-stale
token, every poll 401s, and the only path left is cmux refreshing tokens itself, which
re-introduces the rotation footgun that logs the user out of their own CLI. That single fact
(does each CLI persist refreshed tokens?) decides whether this is a clean read-only feature or a
credential-management minefield. It is verified per-provider in build step 1, and it gates
everything after it.
