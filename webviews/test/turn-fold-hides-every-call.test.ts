// l10n-allow-file: test fixture prompts, commands and replies, not shipped UI.
// A closed "Worked for" hides every tool call of its turn, as chatgpt.com does (read 2026-11-10: a
// closed "Worked for 53s" draws nothing under it but the answer; its notes and its "Ran 2 commands"
// lines draw only once it is opened). The user, 2026-11-10: "it says 'worked for 36s' but if i hide
// it, it still shows a bunch of tool calls ... we need to match and be the same."
// The replies to the person stay in sight (turn-fold-keeps-replies.test.ts); the calls between them
// no longer draw as closed "Ran N commands" lines beside the closed fold.
import { afterEach, beforeEach, expect, test } from "bun:test";
import { MESSAGE_RUN, type AcpmuxActivity, type AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnView, WORKED } from "../src/agent-session/acpmux/conversation/turns";

const START = Date.UTC(2026, 10, 10, 21, 0, 0);
const row = (id: string, kind: string, second: number, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: START + second * 1000,
  ...extra,
});
const calls = (id: string, second: number, count: number): AcpmuxRow =>
  row(id, "activity", second, {
    items: Array.from({ length: count }, (_, index): AcpmuxActivity => ({
      kind: "tool",
      text: "",
      tool: {
        id: `${id}-${index}`,
        title: `rg cmux ${index}`,
        kind: "execute",
        status: "completed",
        command: `rg cmux ${index}`,
      },
    })),
  });

/// A turn that worked for 36s: calls, a reply to the person, more calls, a short note, more calls,
/// then the answer.
const turn: AcpmuxRow[] = [
  row("u-0", "user", 0, { text: "Why does the sidebar jump?" }),
  calls("t-1", 1, 3),
  row("a-middle", "assistant", 10, {
    text: "Found it: the row height changes when the badge mounts.\n\n- The badge is measured late.\n- The row reflows.",
  }),
  calls("t-2", 11, 4),
  row("note", "assistant", 20, { text: "Checking the test next." }),
  calls("t-3", 21, 2),
  row("a-final", "assistant", 34, { text: "Fixed: the badge now reserves its width before it mounts." }),
  row("s-0", "turnSummary", 36, { status: "completed", durationMs: 36_000, toolCount: 9 }),
];

const FAMILIES = ["claude", "codex", "gemini", "muse", undefined];

// The `replies` arm: the replies to the person stay in sight beside the closed fold. The default,
// `answer`, also folds every reply but the final answer (turn-fold-keeps-replies.test.ts).
beforeEach(() => {
  globalThis.cmuxExperiments = { "turn-fold-replies": "replies" };
});

afterEach(() => {
  delete (globalThis as { cmuxExperiments?: unknown }).cmuxExperiments;
});

/// The rows of `view` that draw tool calls: a run of calls, or a run folded with a message beside it.
const callRows = (view: AcpmuxRow[]) =>
  view.filter(
    (shown) =>
      (shown.kind === "activity" && (shown.items ?? []).some((item) => item.tool)) ||
      (shown.kind === MESSAGE_RUN && (shown.messageRun?.work ?? []).some((item) => item.tool)),
  );

for (const family of FAMILIES)
  test(`${family ?? "an unknown family"}: a closed Worked for draws no tool call of its turn`, () => {
    const view = turnView(turn, new Set(), { agentFamily: family, now: START + 60_000 });
    const worked = view.find((shown) => shown.kind === WORKED);
    expect(worked?.foldOpen).toBe(false);
    expect(callRows(view).map((shown) => shown.id)).toEqual([]);
    // The short note folds with the work; the reply to the person and the answer stay.
    const said = view.filter((shown) => shown.kind === "assistant").map((shown) => shown.id);
    expect(said).toEqual(["a-middle", "a-final"]);
  });

for (const family of FAMILIES)
  test(`${family ?? "an unknown family"}: opening the Worked for draws its calls again`, () => {
    const view = turnView(turn, new Set([`${WORKED}-u-0`]), { agentFamily: family, now: START + 60_000 });
    const count = callRows(view)
      .flatMap((shown) => (shown.kind === MESSAGE_RUN ? shown.messageRun!.work : (shown.items ?? [])))
      .filter((item) => item.tool).length;
    expect(count).toBe(9);
  });
