// Reset <card> and its Undo on every page but the appearance ones (cardReset.ts, CardResetBar.tsx).
// Leo (2026-11-19): "improve the usability of background switching. you guys clicking and whatnot,
// make sure you can recover and stuff. for all customizations".
import { afterAll, afterEach, describe, expect, test } from "bun:test";
import { resetCards } from "./cardReset";
import { categories } from "./categories";
import { APPEARANCE_CATEGORIES } from "./appearanceUndo";
import { installDom } from "./testDom";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(() => restore());
const { click, fire, ops, renderPage, run } = await import("./testing");

let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
});

const bar = () => page!.container.querySelector<HTMLElement>("[data-card-reset-bar]");
const undoButton = () => bar()!.querySelector<HTMLButtonElement>("[data-undo]")!;
const redoButton = () => bar()!.querySelector<HTMLButtonElement>("[data-redo]")!;
const resetButton = () => bar()!.querySelector<HTMLButtonElement>('[data-menu="card-reset"]')!;
const resetItem = (name: string) =>
  [...document.querySelectorAll<HTMLElement>('[role="menuitem"]')].find((row) => row.textContent === name);
const rows = () => page!.store.getSnapshot().rows;

describe("the cards a page resets", () => {
  test("every page but the appearance ones offers its cards, in page order", () => {
    const notifications = resetCards("notifications").map((card) => card.title.text);
    expect(notifications).toEqual(["Banners", "Sounds", "Attention Ring", "Feed"]);
    for (const id of APPEARANCE_CATEGORIES) expect(resetCards(id)).toEqual([]);
    const offered = categories.filter((category) => resetCards(category.id).length > 0).map((category) => category.id);
    for (const id of ["general", "updates", "tabs", "terminal", "editor", "browser", "chat", "agents", "privacy"])
      expect(offered).toContain(id);
  });

  test("a card's keys are its rows and the ones behind More Options, never a hidden row", () => {
    const updates = resetCards("updates").flatMap((card) => card.keys);
    expect(updates).toContain("updates.oneClickInstall");
    expect(updates).not.toContain("updates.checkIntervalSeconds");
  });
});

describe("resetting one card", () => {
  const notifications = {
    "notifications.desktop": "always",
    "notifications.dockBadge": false,
    "notifications.timeoutSeconds": 12,
    "notifications.attention.flash": false,
  };

  test("Reset Banners resets only that card's keys, as one undo step Redo puts back", async () => {
    page = await renderPage({ path: "/settings/notifications", mock: { values: notifications } });
    await click(resetButton());
    expect(resetItem("Reset Sounds")?.getAttribute("aria-disabled")).toBe("true");
    expect(resetItem("Reset Attention Ring")?.getAttribute("aria-disabled")).not.toBe("true");
    await click(resetItem("Reset Banners")!);
    for (const key of ["notifications.desktop", "notifications.dockBadge", "notifications.timeoutSeconds"])
      expect(rows().get(key)?.customized).toBe(false);
    expect(rows().get("notifications.attention.flash")?.value).toBe(false);
    expect(page.store.cardHistory.nextUndo?.label).toBe("Reset Banners");
    expect(undoButton().getAttribute("aria-label")).toBe("Undo: Reset Banners");
    // Only the card's set keys were written, one reset each.
    expect(ops(page.provider, "cmux.settings.reset")).toHaveLength(3);

    await click(undoButton());
    expect(rows().get("notifications.desktop")?.value).toBe("always");
    expect(rows().get("notifications.dockBadge")?.value).toBe(false);
    expect(rows().get("notifications.timeoutSeconds")?.value).toBe(12);
    expect(page.store.cardHistory.canUndo).toBe(false);

    await click(redoButton());
    expect(rows().get("notifications.desktop")?.customized).toBe(false);
    expect(rows().get("notifications.attention.flash")?.value).toBe(false);
  });

  test("a managed value stays as the team set it, and a card with only it set offers no reset", async () => {
    page = await renderPage({
      path: "/settings/browser",
      mock: {
        values: { "browser.vimKeys": false, "browser.remoteLocalhost": false, "browser.hibernatePinnedTabs": true },
        managed: {
          "browser.remoteLocalhost": { value: false, source: "profile", reason: "Set by your organization's profile" },
          "browser.hibernatePinnedTabs": {
            value: true,
            source: "profile",
            reason: "Set by your organization's profile",
          },
        },
      },
    });
    await click(resetButton());
    expect(resetItem("Reset Memory")?.getAttribute("aria-disabled")).toBe("true");
    await click(resetItem("Reset Opening Links")!);
    expect(rows().get("browser.vimKeys")?.customized).toBe(false);
    expect(ops(page.provider, "cmux.settings.reset").map((op) => (op as { key: string }).key)).toEqual([
      "browser.vimKeys",
    ]);
    expect(rows().get("browser.remoteLocalhost")?.managed).toBeTruthy();
  });

  test("with nothing set the Reset menu is dimmed; appearance pages keep their own bar", async () => {
    page = await renderPage({ path: "/settings/notifications" });
    expect(resetButton().disabled).toBe(true);
    expect(undoButton().disabled).toBe(true);
    page.unmount();
    page = await renderPage({ path: "/settings/appearance" });
    expect(bar()).toBeNull();
    expect(page.container.querySelector("[data-appearance-bar]")).not.toBeNull();
  });

  test("a look key on Tabs resets in this card's step, not Appearance's", async () => {
    page = await renderPage({
      path: "/settings/tabs",
      mock: { values: { "focusRing.enabled": true } },
    });
    const card = resetCards("tabs").find((item) => item.keys.includes("focusRing.enabled"))!;
    await run(() => page!.store.resetCard(card));
    expect(rows().get("focusRing.enabled")?.customized).toBe(false);
    expect(page.store.cardHistory.canUndo).toBe(true);
    expect(page.store.appearance.canUndo).toBe(false);
    await run(() => page!.store.undoCardReset());
    expect(rows().get("focusRing.enabled")?.value).toBe(true);
  });

  const press = (init: KeyboardEventInit, target: Element = document.body) =>
    fire(target, "keydown", { key: "z", metaKey: true, ...init });

  test("Cmd-Z and Shift-Cmd-Z undo and redo a card reset outside a text field", async () => {
    page = await renderPage({ path: "/settings/notifications", mock: { values: notifications } });
    const banners = resetCards("notifications")[0]!;
    await run(() => page!.store.resetCard(banners));
    (document.activeElement as HTMLElement | null)?.blur();
    await press({});
    expect(rows().get("notifications.desktop")?.value).toBe("always");
    await press({ shiftKey: true, key: "Z" });
    expect(rows().get("notifications.desktop")?.customized).toBe(false);

    const field = document.createElement("input");
    page.container.appendChild(field);
    field.focus();
    await press({}, field);
    expect(rows().get("notifications.desktop")?.customized).toBe(false);
    expect(page.store.cardHistory.canUndo).toBe(true);
  });
});
