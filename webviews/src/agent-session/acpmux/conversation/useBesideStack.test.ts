// l10n-allow-file: test fixtures.
// The asks stack joins the bottom stack's surfaces (useBesideStack.ts `SURFACE`), so the rows beside a
// pinned "Needs your input" card stay in sight, as beside the composer card (Leo, 2026-11-17: "this
// needs your input dismiss row erases things behind it"; transcript-motion-model.md step 4).
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { SURFACE } from "./useBesideStack";

function dock(): HTMLElement {
  const { document } = new JSDOM("<!doctype html><body></body>").window;
  const host = document.createElement("div");
  host.className = "acpmux-dock";
  host.innerHTML = `
    <div class="acpmux-permission acpmux-asks-stack">
      <section class="acpmux-pending-ask">
        <div class="acpmux-pending-ask__head" data-dock-clear=""><span>Needs your input</span></div>
        <fieldset class="acpmux-next-step ui-glass acpmux-stack-material" id="ask-card"></fieldset>
      </section>
    </div>
    <div class="acpmux-running-tray" id="tray"></div>
    <form class="acpmux-composer"><div class="acpmux-composer-box" id="composer"></div></form>`;
  document.body.append(host);
  return host;
}

test("SURFACE takes the asks stack's pinned card with the tray and the composer card", () => {
  const host = dock();
  const ids = [...host.querySelectorAll(SURFACE)].map((node) => node.id);
  expect(ids).toEqual(["ask-card", "tray", "composer"]);
  host.remove();
});

test("SURFACE never takes the pinned ask's line, which paints nothing (dockClear.ts holes it)", () => {
  const host = dock();
  expect(host.querySelector(".acpmux-pending-ask__head")!.matches(SURFACE)).toBe(false);
  host.remove();
});
