// l10n-allow-file: test fixture labels, not shipped UI.
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { playTurnFold, settleTurnFold, startTurnFold, type PlacedRows } from "./turnFold";

test("replacing the live header leaves no fading copy of its clock beside the activity line", () => {
  const dom = new JSDOM("<!doctype html><main></main>", { pretendToBeVisual: true });
  const thread = dom.window.document.querySelector<HTMLElement>("main")!;
  dom.window.HTMLElement.prototype.animate = () => ({ cancel() {}, finish() {} }) as Animation;
  const row = (id: string, index: number, kind: string, text: string) => {
    const node = dom.window.document.createElement("article");
    node.className = `acpmux-row acpmux-${kind}`;
    node.dataset.rowId = id;
    node.setAttribute("aria-posinset", String(index + 1));
    node.textContent = text;
    thread.append(node);
    return node;
  };
  const placed = (ids: string[]): PlacedRows => ({
    count: ids.length,
    idAt: (index) => ids[index],
    tops: ids.map((_, index) => index * 30),
  });
  row("u", 0, "user", "Fix the layout");
  const clock = row("working-u", 1, "working", "Working for 1m");
  const before = placed(["u", "working-u"]);
  const ghosts = new Set<HTMLElement>();
  const fold = startTurnFold(thread, "u", false, before, "chat", 0)!;
  try {
    expect(fold).toBeDefined();
    clock.remove();
    row("activityLine-u", 1, "activityLine", "Edit file 1m");
    expect(playTurnFold(fold, thread, placed(["u", "activityLine-u"]), "chat", ghosts, 1)).toBe(true);
    expect(thread.textContent).not.toContain("Working for");
    expect(thread.textContent).toContain("Edit file 1m");
  } finally {
    settleTurnFold(thread, fold, ghosts);
    dom.window.close();
  }
});
