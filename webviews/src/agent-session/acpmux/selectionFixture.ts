// l10n-allow-file: debug fixture messages, not shipped UI.
// A turn to select text in, for `debug.agent_pane seed_rows` with `fixture: "selection"`: a prompt long
// enough to wrap in its bubble (the person's own words, user 2026-11-15, whose selection there was
// barely visible), and a reply with a paragraph, inline code and a code block, so a capture can show
// the selection and the Reply chip on every chat surface.
import type { AcpmuxRow } from "./model";

export function selectionRows(at: number): AcpmuxRow[] {
  return [
    {
      id: "selection-ask",
      version: 1,
      at,
      kind: "user",
      text:
        "i have been trying to make new workspaces spawn at the top, but it always is inconsistent. i have sent " +
        "many prompts. maybe it's a state ownership issue. please help me fix from first principles. This " +
        "codebase is yours: what it's for and how it's built are your call, and you'll keep building on it. So " +
        "do as much as you can.",
    },
    {
      id: "selection-reply",
      version: 1,
      at: at + 4_000,
      kind: "assistant",
      text:
        "New workspaces take their place from two owners: the sidebar's order and the store's `insertIndex`. " +
        "When both write it, the last write wins, which is why the result changes from run to run. One owner " +
        "fixes it: the store decides the index and the sidebar only reads it.\n\n" +
        "```swift\nlet index = store.insertIndex(for: .newWorkspace)\nsidebar.insert(workspace, at: index)\n```",
    },
    { id: "selection-summary", version: 1, at: at + 4_000, kind: "turnSummary", durationMs: 4_000, toolCount: 0 },
  ] as AcpmuxRow[];
}
