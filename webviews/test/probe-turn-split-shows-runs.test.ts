// l10n-allow-file: test fixture prompts, commands and replies, not shipped UI.
// PROBE (TIP REDS 4, never lands): what `turnView` draws when a prompt that is no steer comes in
// while a turn runs under the shipped `line` look of live-turn-work. It prints the kinds of the rows
// before and after the prompt, for 3 forms of the prompt; it asserts nothing about the product.
import { expect, test } from "bun:test";
import type { AcpmuxActivity, AcpmuxRow } from "../src/agent-session/acpmux/model";
import { turnView } from "../src/agent-session/acpmux/conversation/turns";

let at = 0;
const row = (id: string, kind: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  kind,
  version: 1,
  at: (at += 1_000),
  ...extra,
});
const call = (id: string, status = "completed"): AcpmuxActivity => ({
  kind: "tool",
  text: "",
  tool: { id, title: id, kind: "execute", status, command: id, startedAt: at },
});
const live = (rows: AcpmuxRow[]) => turnView(rows, new Set(), { working: true });
const drawn = (rows: AcpmuxRow[]) =>
  rows
    .filter((entry) => entry.kind !== "date")
    .map((entry) => `${entry.kind}:${entry.id}`)
    .join(" ");

const stretch = (): AcpmuxRow[] => [
  row("u", "user", { text: "Fix the flaky test" }),
  row("run1", "activity", { items: [call("rg retry"), call("git log")] }),
  row("a1", "assistant", { text: "The backoff is scheduled twice." }),
  row("run2", "activity", { items: [call("bun test src/net"), call("git diff")] }),
  row("a2", "assistant", { text: "One more call site." }),
  row("run3", "activity", { items: [call("rg backoff"), call("bun test")] }),
];

test.each([
  ["a plain prompt (no steer, as the red test sends it)", {}],
  ["a steer that waits", { steer: "waiting" }],
  ["a prompt that continues the turn", { continues: true }],
] as [string, Partial<AcpmuxRow>][])("probe: %s", (name, extra) => {
  const before = live(stretch());
  const after = live([...stretch(), row("m", "user", { text: "One more retry loop in the queue.", ...extra })]);
  const runs = (rows: AcpmuxRow[]) => rows.filter((entry) => entry.kind === "activity").length;
  console.log(`PROBE-SPLIT ${name} | before: ${runs(before)} runs in sight | ${drawn(before)}`);
  console.log(`PROBE-SPLIT ${name} | after: ${runs(after)} runs in sight | ${drawn(after)}`);
  expect(before.length).toBeGreaterThan(0);
});
