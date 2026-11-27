// l10n-allow-file: test fixtures.
// A turn's display groups are the daemon's (acpmux-book translate/groups.rs; transcript motion
// model step 9, "The daemon owns shape"). Until the translator writes them on rows, the page's
// `toolGroups` reads the same cases the daemon's test does, so the two cannot drift.
import { expect, test } from "bun:test";
import shared from "../../../../../cmux-tui/crates/acpmux-book/src/translate/fixtures/display-groups-cases.json";
import type { AcpmuxActivity } from "../model";
import { mcpCall } from "./mcpCalls";
import { type ToolGroup, toolGroupKind, toolGroups } from "./toolGroups";

type Tool = NonNullable<AcpmuxActivity["tool"]>;
const calls = shared.calls as Record<string, { class: string; tool: Omit<Tool, "id"> }>;

function entries(names: readonly string[]): { items: AcpmuxActivity[]; ids: Map<AcpmuxActivity, string> } {
  const ids = new Map<AcpmuxActivity, string>();
  const items = names.map((entry) => {
    const [id, call] = entry.split(":") as [string, string];
    const item: AcpmuxActivity =
      call === "thought"
        ? { kind: "thought", text: id }
        : { kind: "tool", text: calls[call]!.tool.title, tool: { id, ...calls[call]!.tool } as Tool };
    ids.set(item, id);
    return item;
  });
  return { items, ids };
}

function drawn(group: ToolGroup, ids: Map<AcpmuxActivity, string>): string[] {
  // A merged thought is a new item whose text begins with the first thought's.
  const id = (item: AcpmuxActivity) => ids.get(item) ?? item.tool?.id ?? item.text.split(/\s/)[0]!;
  switch (group.type) {
    case "group":
      return [`run:${group.kind}`, ...group.items.map(id)];
    case "item":
      return ["item", id(group.item)];
    case "mcp":
      return ["mcp", ...group.items.map(id)];
    case "subsessionGroup":
      return ["subsessionGroup", ...group.items.map(id)];
    case "sendGroup":
      return ["sentGroup", ...group.items.map(id)];
    case "send":
    case "message":
      return ["sent", id(group.item)];
    case "subsession":
      return [group.call.tool === "send" ? "sent" : "card", id(group.item)];
    default:
      return ["card", id(group.item)];
  }
}

test("the page's display groups agree with the daemon's on every shared case", () => {
  expect(shared.cases.length).toBeGreaterThan(20);
  const differ = shared.cases.flatMap((entry) => {
    const { items, ids } = entries(entry.entries);
    const groups = toolGroups(items).map((group) => drawn(group, ids));
    return JSON.stringify(groups) === JSON.stringify(entry.groups) ? [] : [{ name: entry.name, groups }];
  });
  expect(differ).toEqual([]);
});

test("the page classifies each shared call as the daemon is told it is", () => {
  for (const [name, call] of Object.entries(calls)) {
    const tool = { id: name, ...call.tool } as Tool;
    const kind = toolGroupKind(tool);
    const mcp = mcpCall(tool);
    if (call.class.startsWith("mcp:")) {
      expect(mcp && `mcp:${mcp.server}.${mcp.tool}`, name).toBe(call.class);
    } else if (["commands", "reads", "edits", "searches"].includes(call.class)) {
      expect(kind, name).toBe(call.class as typeof kind);
    } else if (call.class === "edits+diff") {
      expect([kind, Boolean(tool.diffs?.length)], name).toEqual(["edits", true]);
    } else if (call.class === "plain") {
      expect([kind, mcp], name).toEqual([undefined, undefined]);
    }
  }
});
