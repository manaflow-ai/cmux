// l10n-allow-file: test fixture prompts, thoughts and commands, not shipped UI.
// A turn folds under "Worked for" only when the fold hides something worth hiding (turns.ts
// `worthFolding`), but only with the Compact Summary for Short Turns setting on (compactShortTurns.ts);
// off, the default, every turn folds under "Worked for", "Worked for 0s" included (Leo: "why isn't there a toggle?").
// Leo, 2026-11-24, on a wake's "Report from Subagent" under "Worked for 0s": "honestly in these cases
// should we just... not do our folding situation? this edge case? cuz otherwise it's so weird"; then
// "what do we do here? math.ceil 1 second? did it even help?", "another worked for 0s" and "well no it
// rounds down apparently. so it's just about what kind of behaviour we want".
import { afterEach, beforeEach, expect, test } from "bun:test";
import type { AcpmuxRow } from "../model";
import { translate, type Translate } from "../i18n";
import { setCompactShortTurns } from "./compactShortTurns";
import { footerLabel, turnView, worthFolding, workedLabel, WORKED } from "./turns";

const t: Translate = (key, values) => translate(key, values, "en");
const START = Date.UTC(2026, 10, 24, 7, 0, 0);

test("the fold's threshold: three work rows, or five seconds, and never under a second", () => {
  expect(worthFolding(2, 4_900)).toBe(false);
  expect(worthFolding(3, 1_000)).toBe(true);
  expect(worthFolding(1, 5_000)).toBe(true);
  expect(worthFolding(9, 999)).toBe(false);
  expect(worthFolding(2, undefined)).toBe(false);
  expect(worthFolding(3, undefined)).toBe(true);
});

const call = (id: string): AcpmuxRow["items"] => [
  { kind: "tool", text: "", tool: { id, title: "gh pr checks", kind: "execute", status: "completed", command: "gh" } },
];
const row = (id: string, kind: string, ms: number, extra: Record<string, unknown> = {}): AcpmuxRow =>
  ({ id, kind, version: 1, at: START + ms, ...extra }) as AcpmuxRow;

/// A wake another session's message started: its prompt, one thought of several lines, one call.
function wake(durationMs: number, calls = 1): AcpmuxRow[] {
  return [
    row("w-0", "user", 0, {
      text: "Lane is green.",
      incoming: {
        kind: "message",
        message: { name: "lane-1", text: "Lane is green.", raw: "Lane is green.", lineOrigin: "peer" },
      },
    }),
    row("w-act", "activity", 10, {
      toolCount: calls,
      items: [
        { kind: "thought", text: "The lane is green.\nNothing to do but note it.\nStop the monitor." },
        ...Array.from({ length: calls }, (_, index) => call(`c-${index}`)![0]!),
      ],
    }),
    row("w-sum", "turnSummary", durationMs, { status: "completed", durationMs, toolCount: calls }),
  ];
}

/// A turn the person asked for: `calls` commands over `durationMs`, no reply.
function asked(durationMs: number, calls: number): AcpmuxRow[] {
  return [
    row("a-0", "user", 0, { text: "Watch the build" }),
    row("a-act", "activity", 10, {
      toolCount: calls,
      items: Array.from({ length: calls }, (_, index) => call(`k-${index}`)![0]!),
    }),
    row("a-sum", "turnSummary", durationMs, { status: "completed", durationMs, toolCount: calls }),
  ];
}

beforeEach(() => void setCompactShortTurns(true));
afterEach(() => void setCompactShortTurns(false));

const view = (rows: AcpmuxRow[]) =>
  turnView(rows, new Set(), { agentFamily: "claude", now: START + 900_000 }).filter((r) => r.kind !== "date");

test("a wake with one call and several lines of thought under a second draws flat, never 0s", () => {
  const shown = view(wake(800));
  expect(shown.some((r) => r.kind === WORKED)).toBe(false);
  for (const line of shown) {
    expect(footerLabel(t, line) ?? "").not.toContain("0s");
    expect(line.kind === WORKED ? workedLabel(t, line) : "").not.toContain("0s");
  }
});

test("a wake that took a few seconds with one call stays flat; five seconds folds", () => {
  expect(view(wake(3_000)).some((r) => r.kind === WORKED)).toBe(false);
  expect(view(wake(5_000)).some((r) => r.kind === WORKED)).toBe(true);
});

test("three calls fold even when quick, but not under a second", () => {
  expect(view(asked(2_000, 3)).some((r) => r.kind === WORKED)).toBe(true);
  expect(view(asked(900, 3)).some((r) => r.kind === WORKED)).toBe(false);
});

test("a real 30 second turn still folds under Worked for 30s, and its footer agrees", () => {
  const shown = view(asked(30_000, 1));
  const header = shown.find((r) => r.kind === WORKED);
  const footer = shown.find((r) => r.kind === "turnSummary");
  expect(header).toBeDefined();
  expect(workedLabel(t, header!)).toBe("Worked for 30s");
  expect(footer).toBeDefined();
  // The header and the footer under it never disagree on the time.
  expect(workedLabel(t, footer!)).toBe(workedLabel(t, header!));
});

test("a header and a footer that disagree fail", () => {
  for (const durationMs of [1_400, 5_000, 59_600, 125_000]) {
    const shown = view(asked(durationMs, 3));
    const header = shown.find((r) => r.kind === WORKED);
    const footer = shown.find((r) => r.kind === "turnSummary");
    expect(header).toBeDefined();
    expect(workedLabel(t, footer!)).toBe(workedLabel(t, header!));
  }
});

// Leo, 07:36Z, on three wakes in a row, each a "Worked for 0s" over a "Report from Subagent": "see
// here's another weirdo case that we need to un-weirdofy".
const report = (index: number, ms: number): AcpmuxRow[] => {
  const id = `r${index}`;
  const at = 20_000 + index * 10_000;
  return [
    row(`backgroundTurn-${id}`, "backgroundTurn", at, {
      background: {
        id,
        trigger: "task_notification",
        running: false,
        hasRows: true,
        cause: { kind: "subagent", status: "completed", weight: "result", summary: `helper-${index} finished` },
      },
    }),
    row(`bt-act-${index}`, "activity", at + 100, {
      inBackground: id,
      toolCount: 1,
      items: [{ kind: "thought", text: "The helper landed.\nNothing to add.\nNote it." }, ...call(`bc-${index}`)!],
    }),
    row(`bt-sum-${index}`, "turnSummary", at + ms, {
      inBackground: id,
      status: "completed",
      durationMs: ms,
      toolCount: 1,
    }),
  ];
};

test("three subagent-report wakes in a row draw flat: no Worked for, no 0s, no dividers", () => {
  const rows = [
    row("ask", "user", 0, { text: "Land the lanes" }),
    row("reply", "assistant", 5_000, { text: "The land monitor is running, so I'll wait." }),
    row("sum", "turnSummary", 6_000, { status: "completed", durationMs: 6_000, toolCount: 0 }),
    ...[0, 1, 2].flatMap((index) => report(index, 300)),
  ];
  const shown = view(rows);
  // The person's own reply-only turn keeps its "Worked for" (`holdsHeader`, so its reply doesn't move up
  // when the turn ends); the wakes after it draw none.
  expect(shown.filter((r) => r.kind === WORKED).map((r) => r.id)).toEqual(["worked-ask"]);
  expect(shown.some((r) => r.kind === "turnSummary" && r.id.startsWith("bt-") && footerLabel(t, r))).toBe(false);
});

test("the same wakes that took a real while still fold", () => {
  const rows = [
    row("ask", "user", 0, { text: "Land the lanes" }),
    row("reply", "assistant", 5_000, { text: "Waiting." }),
    row("sum", "turnSummary", 6_000, { status: "completed", durationMs: 6_000, toolCount: 0 }),
    ...report(0, 30_000),
  ];
  expect(view(rows).some((r) => r.kind === WORKED)).toBe(true);
});

test("with the setting off, the default, a short wake folds under Worked for like any turn", () => {
  setCompactShortTurns(false);
  expect(view(wake(800)).some((r) => r.kind === WORKED)).toBe(true);
  expect(view(asked(2_000, 1)).some((r) => r.kind === WORKED)).toBe(true);
});
