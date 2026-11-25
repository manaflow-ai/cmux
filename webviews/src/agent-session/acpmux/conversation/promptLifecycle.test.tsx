// A prompt in every stage of its lifecycle, drawn as the transcript draws it, offers exactly the
// actions acpmux's table says (acpmux-core `chat/prompt_lifecycle.rs`, its `prompt_lifecycle.json`;
// hq docs/design/user-message-lifecycle.md).
//
// Leo, 2026-11-22: "ok, so is this supposed to be cancellable or what? why am i seeing the edit
// option available after you've already read it? well, the cross vs edit vs anything, we
// need to be able to map out the lifecycle and what should reasonably be possible, when."
//
// The chat below is one of each: an answered first prompt, an answered prompt with a steer read in
// its turn, the running turn's read prompt, a steer still waiting, a prompt still sending and one
// that did not get there. Edit and Fork come from the same trackers the App feeds the bubbles
// (`trackEditableTurns`, `trackPromptTurns`). The composer queue's and the held inbox card's actions
// are their own components' (ComposerQueue.test.tsx, heldMessage.test.tsx); this file checks the
// table names theirs too.
import { afterEach, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import type { AcpmuxRow } from "../model";
import { translate } from "../i18n";
import { TurnActionsContext, type TurnActions } from "./turnActions";
import { UserBubble } from "./UserBubble";
import { PendingSteer } from "./PendingSteer";
import { DeliveryFailure } from "./PromptDelivery";
import { trackEditableTurns, trackPromptTurns } from "./editPrompt";
import { settleReact } from "../../../../test/support/domTeardown";

type Facts = { forks: boolean; turn_before: boolean; steer: boolean };
type Table = {
  stages: { stage: string; next: string[]; cases: { facts: Facts; actions: string[] }[] }[];
  effects: Record<string, string>;
};
const table: Table = JSON.parse(
  readFileSync(
    path.resolve(import.meta.dir, "../../../../../cmux-tui/crates/acpmux-core/prompt_lifecycle.json"),
    "utf8",
  ),
);
const expected = (stage: string, facts: Facts) =>
  table.stages
    .find((each) => each.stage === stage)!
    .cases.find(
      (each) =>
        each.facts.forks === facts.forks &&
        each.facts.turn_before === facts.turn_before &&
        each.facts.steer === facts.steer,
    )!.actions;

// The controls a prompt's row draws, by the name each says. Bookmark is the row mark's (it needs the
// chat's marks), so it is not read here.
const LABELS: Record<string, string> = {
  copy: translate("turn.copy"),
  edit_and_resend: translate("message.edit"),
  fork: translate("turn.fork"),
  cancel: translate("composer.queueEditMessage"),
  send_now: translate("steer.sendNow"),
  retry: translate("turn.retry"),
  edit_in_place: translate("message.edit"),
  remove: translate("prompt.delivery.remove"),
};

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { url: "http://localhost/" });
  for (const key of ["window", "document", "navigator", "Node", "HTMLElement", "Element", "IS_REACT_ACT_ENVIRONMENT"])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    Node: dom.window.Node,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  return dom.window.document.getElementById("root")!;
}

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  await settleReact();
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const at = Date.now() - 60_000;
const user = (id: string, extra: Partial<AcpmuxRow> = {}): AcpmuxRow => ({
  id,
  version: 1,
  kind: "user",
  at,
  text: `prompt ${id}`,
  ...extra,
});
const reply = (id: string): AcpmuxRow => ({ id, version: 1, kind: "agent", at, text: "ok" }) as AcpmuxRow;
const summary = (id: string, seq: number): AcpmuxRow =>
  ({ id, version: 1, kind: "turnSummary", at, seq, status: "completed" }) as AcpmuxRow;
const sending = { state: "sending" as const, promptId: "p-send", sessionId: "s", sentAt: Date.now() - 10_000 };

const rows: AcpmuxRow[] = [
  user("first"),
  reply("a1"),
  summary("t1", 3),
  user("answered"),
  reply("a2"),
  user("steer-landed", { steer: "landed" }),
  reply("a3"),
  summary("t2", 7),
  user("read"),
  reply("a4"),
  user("steer-waiting", { steer: "waiting", steerPromptId: "p-steer" }),
  user("sending", { pending: true, delivery: sending }),
  user("failed", {
    failed: true,
    delivery: { state: "failed", promptId: "p-failed", sessionId: "s", sentAt: at, reason: "transport.refused" },
  } as Partial<AcpmuxRow>),
];

// Each row's stage and facts, as acpmux's table names them.
const STAGES: { id: string; stage: string; facts: Facts }[] = [
  { id: "first", stage: "answered", facts: { forks: true, turn_before: false, steer: false } },
  { id: "answered", stage: "answered", facts: { forks: true, turn_before: true, steer: false } },
  { id: "steer-landed", stage: "answered", facts: { forks: true, turn_before: true, steer: true } },
  { id: "read", stage: "read", facts: { forks: true, turn_before: true, steer: false } },
  { id: "steer-waiting", stage: "steer_waiting", facts: { forks: true, turn_before: true, steer: true } },
  { id: "sending", stage: "sending", facts: { forks: true, turn_before: true, steer: false } },
  { id: "failed", stage: "failed", facts: { forks: true, turn_before: true, steer: false } },
];

/// The bubble's actions as the App builds them for a chat that forks (Claude, Codex) or not.
function actionsFor(chat: readonly AcpmuxRow[], forks: boolean): TurnActions {
  return {
    edit: { seqs: trackEditableTurns(chat, forks).seqs, send: async () => true },
    ...(forks && { fork: () => {}, forkAny: true, promptTurns: trackPromptTurns(chat).seqs }),
    unsteer: async () => "back",
  };
}

async function drawn(row: AcpmuxRow, actions: TurnActions): Promise<string[]> {
  if (!dom) installDom();
  const container = dom!.window.document.getElementById("root")!;
  await act(async () => {
    root ??= createRoot(container);
    root.render(
      <TurnActionsContext.Provider value={actions}>
        <UserBubble
          row={row}
          text={row.text ?? ""}
          pending={
            row.steer === "waiting"
              ? (children, queued) => (
                  <PendingSteer row={row} send={async () => true} queued={queued}>
                    {children}
                  </PendingSteer>
                )
              : undefined
          }
        />
        <DeliveryFailure row={row} />
      </TurnActionsContext.Provider>,
    );
  });
  const names = [...container.querySelectorAll("button")].map(
    (button) => button.getAttribute("aria-label") ?? button.textContent ?? "",
  );
  return names;
}

// The table's actions as the labels they draw (Edit in place and Edit and resend both say "Edit").
const labelsOf = (actions: readonly string[]) => [...new Set(actions.map((action) => LABELS[action]!))].sort();
const drawnLabels = (names: readonly string[]) =>
  [...new Set(Object.values(LABELS))].filter((label) => names.includes(label)).sort();

for (const forks of [true, false]) {
  for (const { id, stage, facts } of STAGES) {
    test(`${forks ? "a chat that forks" : "a chat that cannot fork"}: ${id} (${stage}) offers what the table says`, async () => {
      const row = rows.find((each) => each.id === id)!;
      const want = expected(stage, { ...facts, forks }).filter((action) => action in LABELS);
      const names = await drawn(row, actionsFor(rows, forks));
      // Exactly the table's: an Edit the stage does not offer is the bug Leo saw.
      expect({ id, stage, drawn: drawnLabels(names) }).toEqual({ id, stage, drawn: labelsOf(want) });
    });
  }
}

test("Leo's case: the prompt the agent has read, its turn still running, offers no Edit", async () => {
  const names = await drawn(
    rows.find((each) => each.id === "read")!,
    actionsFor(rows, true),
  );
  expect(names).not.toContain(translate("message.edit"));
  expect(names).toContain(translate("turn.copy"));
});

test("once its turn ends, the read prompt edits and resends through the turn before it", async () => {
  const ended = [...rows.slice(0, 10), summary("t3", 11)];
  const seqs = trackEditableTurns(ended, true).seqs;
  expect(seqs.get("read")).toBe(7);
  // A steer never edits and resends: its turn opened with another prompt.
  expect(seqs.has("steer-landed")).toBe(false);
  // Every prompt of an ended turn forks through it, the steer read in it too.
  const turns = trackPromptTurns(ended).seqs;
  expect([turns.get("answered"), turns.get("steer-landed"), turns.get("read")]).toEqual([7, 7, 11]);
});

test("the trackers kept across snapshots agree with a fresh read as the turn ends", () => {
  const running = rows.slice(0, 10);
  const ended = [...running, summary("t3", 11)];
  const keptEdits = trackEditableTurns(ended, true, trackEditableTurns(running, true));
  expect([...keptEdits.seqs]).toEqual([...trackEditableTurns(ended, true).seqs]);
  const keptTurns = trackPromptTurns(ended, trackPromptTurns(running));
  expect([...keptTurns.seqs]).toEqual([...trackPromptTurns(ended).seqs]);
});

test("the table names every stage, and only the queue and an unread steer offer the ✕", () => {
  expect(table.stages.map((each) => each.stage)).toEqual([
    "composing",
    "sending",
    "waiting_for_host",
    "queued",
    "steer_waiting",
    "held_in_inbox",
    "failed",
    "read",
    "answered",
  ]);
  for (const { stage, cases } of table.stages)
    for (const { actions } of cases)
      if (actions.includes("cancel")) expect(["queued", "steer_waiting"]).toContain(stage);
  expect(table.effects.edit_and_resend).toBe("forks");
});
