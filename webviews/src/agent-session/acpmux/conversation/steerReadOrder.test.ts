// l10n-allow-file: test fixture prompts and replies, not shipped UI.
// The person's message sent into a running turn and read there (a steer that landed) draws where it
// went in, above the reply that answers it, whatever opened the turn (Leo, 2026-11-12, on his
// question drawn under its own answer: "in this case you didnt respond to me at all...").
import { expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { turnView } from "./turns";
import { isVisiblyEmptyMessage } from "./visibleMessage";

let at = 0;
const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: (at += 1_000),
  ...extra,
});
const summary = (id: string) => row(id, "turnSummary", { status: "completed", durationMs: 2_000, toolCount: 2 });
const drawn = (rows: AcpmuxRow[]) =>
  turnView(rows, new Set())
    .filter((entry) => entry.kind !== "date" && !isVisiblyEmptyMessage(entry))
    .map((entry) => entry.id);
const run = (id: string, title: string) =>
  row(id, "activity", {
    toolCount: 1,
    items: [{ kind: "tool", tool: { id: `${id}-call`, title, kind: "execute", status: "completed" } }] as never,
  });
const notice = (id: string, title: string) =>
  row(id, "user", {
    text: title,
    untyped: true,
    incoming: {
      kind: "message",
      message: {
        name: "",
        text: "",
        raw: title,
        notice: { sender: "", system: true, task: true, severity: "info", title, links: [] },
      },
    },
  } as Partial<AcpmuxRow>);

const ARMS: Record<string, string>[] = [
  {},
  ...["nested-open", "nested", "header", "split"].map((arm) => ({ "turn-fold-steered": arm })),
  { "turn-fold-replies": "answer" },
];

for (const arms of ARMS)
  for (const [name, opener] of [
    ["the person's prompt", () => row("prompt", "user", { text: "Unwind the bottom area" })],
    ["a background notice", () => notice("prompt", "Background command finished: make (exit 0)")],
  ] as const)
    test(`a steer read mid-turn draws before the reply that answers it, in a turn ${name} opened ${JSON.stringify(arms)}`, () => {
      at = 0;
      (globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments = arms;
      const rows = [
        opener(),
        run("run-1", "git status"),
        row("steer", "user", { text: 'should this really be labelled as "cmux"?', steer: "landed" }),
        run("run-2", "SendMessage"),
        row("answer", "assistant", { text: 'No, "cmux" names the app; the chip will name the source.' }),
        summary("s"),
        // The next turn, which answers something else.
        notice("next", "Background command finished: ls (exit 0)"),
        row("next-reply", "assistant", { text: "Your top-four priority list is unchanged." }),
        summary("s2"),
      ];
      const ids = drawn(rows);
      delete (globalThis as { cmuxExperiments?: Record<string, string> }).cmuxExperiments;
      expect(ids).toContain("steer");
      expect(ids.indexOf("steer")).toBeLessThan(ids.indexOf("answer"));
      expect(ids.indexOf("answer")).toBeLessThan(ids.indexOf("next-reply"));
    });
