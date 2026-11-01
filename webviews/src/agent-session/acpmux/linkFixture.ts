// l10n-allow-file: debug fixture messages, not shipped UI.
// A turn whose reply links a pull request on a synthetic page, for `debug.agent_pane seed_rows` with
// `fixture: "link"`: a capture clicks the link and shows where it opens (cmux#28544). The page is
// example.com, so a still never shows a live GitHub page with real people's names on it.
import type { AcpmuxRow } from "./model";

/// The pull request page the reply links.
export const LINKED_PAGE = "https://example.com/pull/4321";

export function linkRows(at: number): AcpmuxRow[] {
  return [
    { id: "link-ask", version: 1, at, kind: "user", text: "Open the pull request for the right pane fix" },
    {
      id: "link-reply",
      version: 1,
      at: at + 3_000,
      kind: "assistant",
      text: `The fix is up for review: [Reuse the pane on the right](${LINKED_PAGE}).`,
    },
    { id: "link-summary", version: 1, at: at + 3_000, kind: "turnSummary", durationMs: 3_000, toolCount: 0 },
  ] as AcpmuxRow[];
}
