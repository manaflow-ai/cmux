// l10n-allow-file: test fixture labels, not shipped UI.
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { playTurnFold, settleTurnFold, startTurnFold, type PlacedRows } from "./turnFold";
import { openDeclarations } from "../../../layout/motionContract";

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
    row("activityLine-u", 1, "activityLine", "Edit file 1m");
    expect(playTurnFold(fold, thread, placed(["u", "activityLine-u"]), "chat", ghosts, 1)).toBe(true);
    expect(thread.textContent).not.toContain("Working for");
    expect(thread.textContent).toContain("Edit file 1m");
  } finally {
    settleTurnFold(thread, fold, ghosts);
    dom.window.close();
  }
});

test("a turn fold declares the rows it moves as the toggle's expand while it plays, and only then", () => {
  const dom = new JSDOM("<!doctype html><main></main>", { pretendToBeVisual: true });
  const thread = dom.window.document.querySelector<HTMLElement>("main")!;
  dom.window.HTMLElement.prototype.animate = () => ({ cancel() {}, finish() {} }) as Animation;
  const row = (id: string, index: number) => {
    const node = dom.window.document.createElement("article");
    node.className = "acpmux-row";
    node.dataset.rowId = id;
    node.setAttribute("aria-posinset", String(index + 1));
    thread.append(node);
    return node;
  };
  const above = row("u", 0);
  const line = row("worked", 1);
  const below = row("answer", 2);
  const placed: PlacedRows = { count: 3, idAt: (index) => ["u", "worked", "answer"][index], tops: [0, 30, 60] };
  const folds = () => openDeclarations().filter((declaration) => declaration.by === "turn fold");
  const fold = startTurnFold(thread, "worked", true, placed, "chat", 0)!;
  try {
    expect(folds()).toHaveLength(1);
    expect(folds()[0]).toMatchObject({ event: "expand", scope: "targets" });
    expect(folds()[0]!.targets).toContain(line);
    expect(folds()[0]!.targets).toContain(below);
    expect(folds()[0]!.targets).not.toContain(above);
  } finally {
    settleTurnFold(thread, fold, new Set());
    dom.window.close();
  }
  expect(folds()).toHaveLength(0);
});
