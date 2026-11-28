// Temporary debug probe (wrc-transcript-b); removed before commit.
import { expect, test } from "bun:test";
import { GALLERY_NOW } from "../src/gallery/clock";
import { turnViewFrom } from "../src/agent-session/acpmux/conversation/turns";
import fullConversation from "../src/gallery/parity/fullConversation.gallery";
import { withSubagentLines } from "../src/agent-session/acpmux/subagents/runningTray";

test("probe", () => {
  const snapshot = fullConversation.variants.tour!.snapshot;
  const input = withSubagentLines(snapshot.rows);
  const projected = turnViewFrom(input, new Set(), { working: snapshot.isWorking, agentFamily: "codex", now: GALLERY_NOW });
  const brief = (r: any) => [r.id, r.kind, r.subagents?.map((s: any) => s.id), r.items?.length, r.folded ?? r.open];
  console.log("WTBPAR in " + JSON.stringify(input.map(brief)));
  console.log("WTBPAR out " + JSON.stringify(projected.rows.map(brief)));
  const deep = JSON.stringify(projected.rows);
  console.log("WTBPAR mentions " + (deep.match(/tour-settings-corner-review/g)?.length ?? 0));
  const w = projected.rows.filter((r: any) => JSON.stringify(r).includes("tour-settings-corner-review"));
  console.log("WTBPAR holders " + JSON.stringify(w.map((r: any) => [r.id, r.kind, Object.keys(r)])));
  expect("probe-output-retained").toBe("");
});
