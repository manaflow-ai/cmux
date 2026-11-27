// l10n-allow-file: browser fixture labels, not shipped UI.
// Real conversation CSS on the action groups rendered by UserBubble/IncomingMessageLine.
// A row's unrelated popup must not reveal its message actions.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { chromium, webkit } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("message-actions-menu-reveal.test.ts", async () => {
  const css = readFileSync(
    path.resolve(import.meta.dir, "../src/agent-session/acpmux/conversation/conversation.css"),
    "utf8",
  );
  for (const [engine, launcher] of Object.entries({ chromium, webkit })) {
    test(`${engine}: received menu stays revealed and lit for either open marker`, async () => {
      const browser = await launcher.launch({ headless: true });
      try {
        const page = await browser.newPage({ reducedMotion: "reduce" });
        await page.setContent(`<!doctype html><style>${css}</style>
          <div class="cv-received" style="--cv-text:rgb(40,40,40);--cv-fg:rgb(40,40,40)">
            <span class="cv-received-actions">
              <button id="menu" aria-haspopup="menu" aria-expanded="false">Actions</button>
              <button id="other" aria-haspopup="listbox">Choose</button>
            </span>
          </div>
          <button id="outside" style="position:fixed;top:300px;left:600px">Outside</button>`);
        const state = () =>
          page.locator("#menu").evaluate((node) => ({
            opacity: getComputedStyle(node.parentElement!).opacity,
            color: getComputedStyle(node).color,
            background: getComputedStyle(node).backgroundColor,
          }));
        await page.locator("#outside").focus();
        await page.mouse.move(700, 400);
        const closed = await state();
        expect(closed.opacity).toBe("0");
        let expanded: Awaited<ReturnType<typeof state>> | undefined;
        for (const marker of ["aria-expanded", "data-popup-open"]) {
          await page.locator("#menu").hover();
          await page.locator("#menu").evaluate((node, attr) => node.setAttribute(attr, "true"), marker);
          await page.locator("#outside").focus();
          await page.mouse.move(700, 400);
          const open = await state();
          expect(open.opacity).toBe("1");
          expect(open.color).not.toBe(closed.color);
          expect(open.background).not.toBe(closed.background);
          if (expanded) expect(open).toEqual(expanded);
          else expanded = open;
          await page.locator("#menu").evaluate((node, attr) => node.removeAttribute(attr), marker);
          expect(await state()).toEqual(closed);
          // An unrelated popup cannot reveal or light the menu trigger.
          await page.locator("#other").evaluate((node, attr) => node.setAttribute(attr, "true"), marker);
          expect(await state()).toEqual(closed);
          await page.locator("#other").evaluate((node, attr) => node.removeAttribute(attr), marker);
        }
      } finally {
        await browser.close();
      }
    }, 60_000);
    for (const kind of ["user", "received"]) {
      test(`${engine}: ${kind} actions follow only their own open menu`, async () => {
        const browser = await launcher.launch({ headless: true });
        try {
          const page = await browser.newPage({ reducedMotion: "reduce" });
          const actions = kind === "user" ? "cv-user__actions" : "cv-received-actions";
          await page.setContent(`<!doctype html><style>${css}</style>
            <button id="outside" style="position:fixed;top:300px;left:600px">Outside</button>
            <div id="row" class="cv-${kind}" style="width:400px;min-height:100px">
              <button id="unrelated" aria-haspopup="dialog" aria-expanded="false">Details</button>
              <div id="actions" class="${actions}">
                <button id="menu" aria-haspopup="menu" aria-expanded="false">Actions</button>
                <button id="other-action" aria-haspopup="listbox" aria-expanded="false">Choose</button>
              </div>
            </div>`);
          const opacity = (selector: string) =>
            page.locator(selector).evaluate((node) => getComputedStyle(node).opacity);
          const expectState = async (value: string) => {
            expect(await opacity("#actions")).toBe(value);
          };
          const leave = async () => {
            await page.locator("#outside").focus();
            await page.mouse.move(700, 400);
          };
          await leave();
          await expectState("0");
          await page.locator("#row").hover();
          await expectState("1");
          await leave();
          await page.locator("#menu").focus();
          await expectState("1");
          await page.locator("#menu").evaluate((node) => {
            node.addEventListener("click", () => node.setAttribute("aria-expanded", "true"));
          });
          await page.locator("#menu").click();
          await leave();
          await expectState("1");
          await page.locator("#menu").evaluate((node) => node.setAttribute("aria-expanded", "false"));
          await expectState("0");
          // Both another popup in the action group and any popup elsewhere in the row are unrelated.
          for (const [id, popup] of [
            ["other-action", "dialog"],
            ["other-action", "listbox"],
            ["unrelated", "dialog"],
            ["unrelated", "listbox"],
            ["unrelated", "menu"],
          ]) {
            await page.locator(`#${id}`).evaluate((node, type) => {
              node.setAttribute("aria-haspopup", type);
              node.setAttribute("aria-expanded", "true");
            }, popup!);
            await expectState("0");
            await page.locator(`#${id}`).evaluate((node) => node.setAttribute("aria-expanded", "false"));
          }
        } finally {
          await browser.close();
        }
      }, 60_000);
    }
  }
});
