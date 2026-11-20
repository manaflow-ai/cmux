// l10n-allow-file: test fixtures.
// An agent row names the beads its chat works on (acpmux `bead link`, the summary's `beads`) beside its
// done state (Leo, 2026-11-19: "linking beads to agents and vice versa").
import { describe, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import { sessionBeads, sessionEntry } from "../sessionList";
import { startedSessions } from "../started/startedSessions";
import { ChildSessionRows } from "./ChildSessionRows";

describe("agent rows link beads", () => {
  test("a session's beads are the summary's, as acpmux checked and ordered them", () => {
    expect(sessionBeads(["cx-a", "cx-b.2"])).toEqual(["cx-a", "cx-b.2"]);
    expect(sessionBeads([])).toBeUndefined();
    expect(sessionBeads(undefined)).toBeUndefined();
    // The tags alone are not read: acpmux owns which tags are beads.
    expect(sessionEntry({ sessionId: "s", tags: { "bead:cx-a": "1" } }).beads).toBeUndefined();
  });

  test("a done child chat's row says Done and names its beads", () => {
    const entries = [
      sessionEntry({ sessionId: "parent" }),
      sessionEntry({
        sessionId: "child",
        title: "Fix the row",
        spawnedBy: "parent",
        status: "idle",
        lastTurn: { status: "completed" },
        tags: { "bead:cx-cus7j.230": "1", "bead:cx-0op": "2" },
        beads: ["cx-0op", "cx-cus7j.230"],
      }),
      sessionEntry({ sessionId: "plain", title: "No bead", spawnedBy: "parent", status: "idle" }),
    ];
    const started = startedSessions(entries, "parent");
    expect(started.find((s) => s.sessionId === "child")?.beads).toEqual(["cx-0op", "cx-cus7j.230"]);
    expect(started.find((s) => s.sessionId === "plain")?.beads).toBeUndefined();
    const html = renderToStaticMarkup(<ChildSessionRows sessions={started} />);
    expect(html).toContain('data-beads="cx-0op cx-cus7j.230"');
    expect(html).toContain("cx-0op, cx-cus7j.230");
    expect(html.match(/acpmux-summary-agent__beads/g)?.length).toBe(1);
    expect(html).toContain('data-status="done"');
  });
});
