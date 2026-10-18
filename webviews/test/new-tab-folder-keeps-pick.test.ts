// l10n-allow-file: test fixtures, not shipped UI.
// Leo 2026-10-18: on a New Tab, picking Haiku and then a folder put the chip back on the saved
// default (Sonnet, High). A pick made on the page holds across a folder pick; only a page with no
// pick names the new folder's last pick or the default.
import { expect, test } from "bun:test";
import { applySwitch } from "../src/agent-session/acpmux/harnessSwitch";
import { newTabStart } from "../src/agent-session/acpmux/newtab/chipDefaults";
import { withDraftFolder } from "../src/agent-session/acpmux/newtab/draftFolder";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";

const effort = (value: string) => ({
  id: "effort",
  name: "Reasoning",
  category: "thought_level",
  type: "select",
  currentValue: value,
  options: ["low", "medium", "high"].map((level) => ({ value: level, name: level })),
});
// acpmux's catalog: Claude Code's next chat starts on the saved Sonnet, High.
const catalog = [
  {
    id: "claude",
    name: "Claude Code",
    family: "claude",
    models: ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"].map((id) => ({ id, name: id })),
    start: { model: "claude-sonnet-5-5", modelSource: "saved", effort: "high", effortSource: "saved" },
  },
] as unknown as AcpmuxSnapshot["catalog"];
const empty = {
  type: "snapshot",
  protocolVersion: 1,
  rows: [],
  sessions: [],
  connection: "test",
  isWorking: false,
  queue: [],
  canLoadOlder: false,
  catalog,
} as unknown as AcpmuxSnapshot;
const profiles = new Map([["claude", { configOptions: [effort("high")] }]]) as never;
const agents = [{ id: "claude", name: "Claude Code" }];

/// What the New Tab's chips name after the page's folder is `folder` (App composerSnapshot, then
/// NewTabScreen's newTabStart).
function chips(snapshot: AcpmuxSnapshot, folder: string) {
  const { snapshot: chip } = newTabStart(withDraftFolder(snapshot, folder), agents, "claude", folder, undefined);
  const level = chip.summary?.configOptions?.find((option) => option.id === "effort")?.currentValue;
  return { model: chip.summary?.model, effort: level };
}

test("a model and effort picked on a New Tab hold when a folder is picked after them", () => {
  // The chips' picks start a deferred switch that holds them (DefaultComposerChips startsChat).
  const picked = applySwitch(
    empty,
    {
      intent: {
        harness: "claude",
        cwd: "/Users/dev",
        shown: false,
        phase: "starting",
        config: { model: "claude-haiku-5-5", options: { effort: "low" } },
        queued: [],
      },
    } as never,
    catalog,
    profiles,
  );
  expect(chips(picked, "/Users/dev/proj-b")).toEqual({ model: "claude-haiku-5-5", effort: "low" });
});

test("with nothing picked, a folder pick names what the next chat starts on there", () => {
  expect(chips(empty, "/Users/dev/proj-b").model).toBe("claude-sonnet-5-5");
});
