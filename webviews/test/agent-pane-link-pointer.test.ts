// Every link in the agent chat shows the pointing hand over all of it (Leo 2026-10-22, ask-d0a928253d:
// "links when i hover them in the chat esp the pr things i need to have the cursor switch to the
// clickable look"). A reply's links sit in `.selectable` content, where desktop.css gives every
// descendant `cursor: auto`: a chip's label drew the I-beam and its icon the arrow, though the chip
// itself was a pointer. Links outside reply text (the pull request hover card, the header's pull
// request popover, the pull request bar above the composer) took desktop.css's arrow for controls.
// This loads the real stylesheets in the bundle's order (scripts/cmux-next/build-agent-pane-web.sh)
// and reads the computed cursor of each link and of everything inside it.
import { readFileSync } from "node:fs";
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("agent-pane-link-pointer.test.ts", async () => {
  setDefaultTimeout(60_000);
  const src = path.resolve(import.meta.dir, "../src");
  const css = [
    "pages/shared/desktop.css",
    "agent-session/shared/styles.css",
    "ui/popupSurface.css",
    "agent-session/acpmux/styles.css",
    "agent-session/acpmux/conversation/conversation.css",
    "agent-session/acpmux/chips/chips.css",
    "agent-session/acpmux/summary/summary.css",
    "agent-session/acpmux/header/header.css",
    "agent-session/acpmux/needsYou/needsYou.css",
    "agent-session/acpmux/started/startedSessions.css",
  ]
    .map((file) => readFileSync(path.join(src, file), "utf8"))
    .join("\n");
  const icon = `<svg class="cv-chip__icon" width="13" height="13"><rect width="13" height="13"/></svg>`;
  // Each link as its component renders it; `data-kind` names it in a failure.
  const reply =
    `<div class="cv-md selectable"><p>` +
    `<a data-kind="web link" class="cv-link cv-chip is-web" href="https://example.com"><span class="cv-chip__label">the docs</span></a> ` +
    `<a data-kind="pull request chip" class="cv-link cv-chip is-web is-ref" href="https://github.com/o/r/pull/1">${icon}<span class="cv-chip__label">o/r#1</span></a> ` +
    `<a data-kind="link with an icon" class="cv-link cv-chip is-web" href="https://arxiv.org/abs/1">${icon}<span class="cv-chip__label">paper</span></a> ` +
    `<button data-kind="path chip" type="button" class="cv-chip is-path">${icon}<span class="cv-chip__label">app.ts</span></button> ` +
    `<a data-kind="app link" class="cv-link is-app" href="cmux://settings"><strong>Settings</strong></a> ` +
    `<a data-kind="image link" class="cv-link is-image" href="https://example.com/a.png">${icon}a.png</a> ` +
    `<button data-kind="needs-you link" type="button" class="cv-link is-needs-you"><span class="acpmux-needs-you-dot"></span>the ask</button> ` +
    `<button data-kind="started chat chip" type="button" class="acpmux-started-chip">the chat</button> ` +
    `<span data-kind="tool file link" role="link" tabindex="0" class="cv-tool__file is-link">a.ts</span>` +
    `</p></div>`;
  // Portaled or above the composer: outside `.selectable`.
  const outside =
    `<div class="ui-glass cv-link-preview acpmux-pr-card"><div class="acpmux-pr-card__facts">` +
    `<a data-kind="pull request card reference" class="acpmux-pr-card__ref" href="https://github.com/o/r/pull/1">o/r#1</a></div></div>` +
    `<div class="acpmux-pr-status"><a data-kind="pull request popover title" class="acpmux-pr-title" href="https://github.com/o/r/pull/1">Fix it</a>` +
    `<ul class="acpmux-pr-checks"><li class="acpmux-pr-check"><a data-kind="pull request popover check" href="https://github.com/o/r/runs/1">build</a></li></ul></div>` +
    `<section class="acpmux-pr-dock"><div class="acpmux-pr-dock__chip">` +
    `<a data-kind="pull request bar" class="acpmux-pr-dock__bar" href="https://github.com/o/r/pull/1">${icon}<span class="acpmux-pr-dock__number">#1</span><span class="acpmux-pr-dock__title">Fix it</span></a></div></section>` +
    `<div class="acpmux-turn-preview"><a data-kind="preview address" class="acpmux-turn-preview-address" href="http://localhost:3000"><span class="acpmux-turn-preview-title">App</span></a></div>`;

  const engines: [string, BrowserType][] = [
    ["chromium", chromium],
    ["webkit", webkit],
  ];
  for (const [name, engine] of engines) {
    let browser: Browser | undefined;
    try {
      await (await engine.launch({ headless: true })).close();
    } catch {
      console.warn(`agent-pane-link-pointer: skipping ${name} (run \`bunx playwright install ${name}\`)`);
      describe.skip(`link pointer: ${name}`, () => test(name, () => {}));
      continue;
    }
    describe(`link pointer: ${name}`, () => {
      beforeAll(async () => {
        browser = await engine.launch({ headless: true });
      });
      afterAll(async () => {
        await browser?.close();
      });

      test("every link is the pointing hand over its text and icon", async () => {
        const page = await browser!.newPage();
        await page.setContent(`<style>${css}</style>${reply}${outside}`);
        const wrong = await page.evaluate(() =>
          [...document.querySelectorAll<HTMLElement>("[data-kind]")].flatMap((link) =>
            [link, ...link.querySelectorAll<Element>("*")]
              .map((element) => ({ element, cursor: getComputedStyle(element).cursor }))
              .filter(({ cursor }) => cursor !== "pointer")
              .map(({ element, cursor }) => `${link.dataset.kind}: <${element.tagName.toLowerCase()}> ${cursor}`),
          ),
        );
        await page.close();
        expect(wrong).toEqual([]);
      });
    });
  }
});
