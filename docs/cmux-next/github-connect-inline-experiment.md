# Inline GitHub connection experiment

`github-connect-inline` is off by default. Its first slice adds a Connect GitHub button to a
GitHub MCP call whose result contains the bridge's structured, retryable `github.not_connected`
refusal. A collapsed MCP group exposes the same action. The original failure remains readable.

In the gallery, open **Experimental → Inline GitHub connection** and compare the Off and On arms.
The available, failed, denied, and grouped fixtures use a recording host: they never connect an
account. For desktop dogfood, set `cmux.experiments` in the agent pane's localStorage to a JSON
object containing `"github-connect-inline": "on"`, preserving any other experiment keys, and reload
the pane. Remove that key to return to the default.

A click calls the existing pane adapter `github.connect`, which opens the app's shared GitHub
connection flow. It never executes a tool-provided action or URL. While that request is pending,
the button is disabled. A launch failure keeps the button and adds the existing localized error.
An opened browser is not proof of connection, so this slice never displays a Connected state.

This is the launch portion of follow-up 1 in the
[remote integrations design](https://github.com/manaflow-ai/cmuxterm-hq/blob/main/docs/design/remote-integrations.md).
Installation reuse, chat/repository return context, callback return, verified connection, automatic
retry, and shell stderr matching remain follow-ups. The native iPhone transcript does not consume
this web renderer; this experiment does not claim native iPhone parity or change its connection UI.
Keep the experiment off by default until those paths are complete and verified.

The design's baseline is **8 taps, 5 screens**. Its targets are **1 tap** for an installation that
already covers the repository, **2 taps** when installation or repository access is missing, and
**0 additional taps** to retry. These are design targets, not results measured by this launch-only
experiment. The gallery click checks only one action from the inline button to `github.connect`.

Focused checks: `githubConnectModel.test.ts` pins the exact structured contract and rejects prose,
unrelated servers/actions, policy denials, malformed and oversized results; `GitHubConnectCard.test.tsx`
checks the default-off gate, click dispatch, duplicate suppression, and retry after a failed launch.
The gallery exercises the actual MCP row and group renderers at narrow and desktop widths.
