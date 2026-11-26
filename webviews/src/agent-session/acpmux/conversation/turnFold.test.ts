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
  // The turn's header, running: its chevron's slot held unseen (WorkingFor.tsx).
  const clock = row("worked-u", 1, "worked", "Working for 1m");
  clock.insertAdjacentHTML("beforeend", '<svg class="cv-worked__chevron is-reserved"></svg>');
  const before = placed(["u", "worked-u"]);
  const ghosts = new Set<HTMLElement>();
  const fold = startTurnFold(thread, "u", false, before, "chat", 0)!;
  try {
    expect(fold).toBeDefined();
    clock.remove();
    row("thinking-live", 1, "thinking", "Edit file 1m");
    expect(playTurnFold(fold, thread, placed(["u", "thinking-live"]), "chat", ghosts, 1)).toBe(true);
    expect(thread.textContent).not.toContain("Working for");
    expect(thread.textContent).toContain("Edit file 1m");
  } finally {
    settleTurnFold(thread, fold, ghosts);
    dom.window.close();
  }
});
