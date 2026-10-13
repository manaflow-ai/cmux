// Leo, 2026-10-12: popovers, menus and tooltips were glass at 92% with a blur, so the text under
// them showed through (the New Tab folder popover over the Chats list read as text on text). Every
// one is now the solid popup surface, `--surface-popup`: the host's `--cmux-popup-surface`, the
// same opaque fill as the native overlays (`Palette.popupSurface`), with no backdrop blur. The two
// web tooltips (Base UI's `.ui-tooltip`, the title tooltip) also match the native tooltip: popup
// surface, primary ink, 5 px radius, 4×8 padding, a separator hairline and the caption font.
//
// The pages are the real stylesheets with the variables the host sets, in a see-through window
// (a translucent elevated background). The engines come from `playwright install chromium
// webkit`; where they are not installed, the cases are skipped and say so.
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { chromium, webkit, type Browser, type BrowserType, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("popup-surface.test.ts", async () => {
  setDefaultTimeout(120_000);
  const source = path.resolve(import.meta.dir, "../src");
  const read = (...files: string[]) =>
    files
      .map((file) => fs.readFileSync(path.join(source, file), "utf8"))
      .join("\n")
      // A page's bundler resolves these; the fixture inlines the sheet itself.
      .replace(/^@import .*$/gm, "");

  const engines: [string, BrowserType][] = [];
  for (const engine of [
    ["chromium", chromium],
    ["webkit", webkit],
  ] as [string, BrowserType][]) {
    try {
      await (await engine[1].launch({ headless: true })).close();
      engines.push(engine);
    } catch {
      console.warn(`popup-surface: skipping ${engine[0]} (run \`bunx playwright install ${engine[0]}\`)`);
    }
  }

  // The host's theme (WebTheme.swift) in a see-through window: the elevated background is translucent.
  const POPUP = "rgb(52, 49, 68)";
  const TEXT = "rgb(224, 222, 244)";
  const SECONDARY = "rgb(144, 140, 170)";
  const SEPARATOR = "rgba(224, 222, 244, 0.12)";
  const theme = [
    `--cmux-popup-surface:${POPUP}`,
    `--cmux-text:${TEXT}`,
    `--cmux-text-secondary:${SECONDARY}`,
    `--cmux-separator:${SEPARATOR}`,
    "--cmux-elevated-background:rgba(38, 35, 58, 0.6)",
    "--cmux-surface-solid:rgb(25, 23, 36)",
    "--cmux-surface-background:rgba(25, 23, 36, 0)",
    `--agent-text:${TEXT}`,
    "--agent-accent-text:rgb(25, 23, 36)",
    "--agent-page-bg:rgba(25, 23, 36, 0)",
    "--page-elevated:rgba(38, 35, 58, 0.6)",
  ].join(";");
  const LONG = "A tooltip whose text runs on for a good while so that it has to wrap onto more lines. ".repeat(3);
  const tooltips = `<div class="ui-tooltip" id="ui-tooltip">${LONG}</div>
<div class="ui-title-tooltip" id="title-tooltip"><span class="ui-tooltip-text">${LONG}</span><span class="ui-tooltip-hint" id="hint">⌘T</span></div>`;

  // First-party pages: desktop.css, then ui.css and its popup surface.
  const pages = {
    css: read(
      "pages/shared/desktop.css",
      "pages/shared/pageBase.css",
      "ui/popupSurface.css",
      "ui/ui.css",
      "icon-picker/styles.css",
      "pages/markdown/styles.css",
      "pages/home-channels/styles.css",
      "pages/editor/styles.css",
    ),
    body: `<div class="ui-positioner"><div class="ui-popup" id="menu">Menu</div></div>
${tooltips}
<div class="page-menu" id="page-menu">Sort</div>
<div class="icon-bar-pill" id="icon-bar-pill">Icons</div>
<div class="md-link-card" id="md-link-card">https://example.com</div>
<div class="md-link-popover" id="md-link-popover">Edit link</div>
<div class="hc-msg-toolbar" id="hc-msg-toolbar">React</div>
<div class="hc-switcher" id="hc-switcher">Switch channel</div>
<div id="editor-widget" style="background: var(--cmux-editor-widget-background)">Suggest</div>`,
    surfaces: [
      "menu",
      "ui-tooltip",
      "title-tooltip",
      "page-menu",
      "icon-bar-pill",
      "md-link-card",
      "md-link-popover",
      "hc-msg-toolbar",
      "hc-switcher",
      "editor-widget",
    ],
  };
  // The agent pane: desktop.css, the popup surface, then the pane's sheets (build-agent-pane-web.sh).
  const pane = {
    css: read(
      "pages/shared/desktop.css",
      "ui/popupSurface.css",
      "agent-session/acpmux/styles.css",
      "agent-session/acpmux/changes/changes.css",
      "agent-session/acpmux/composerControls.css",
      "agent-session/acpmux/composerLocation.css",
      "agent-session/acpmux/modelPicker.css",
      "agent-session/acpmux/summary/summary.css",
      "agent-session/acpmux/header/header.css",
      "agent-session/acpmux/newtab/screen.css",
    ),
    body: `<div class="acpmux-shell">
<div class="acpmux-menu" id="cascade">Model</div>
<div class="acpmux-context-pop" id="context-pop">Context</div>
<div class="acpmux-slash-menu" id="slash">/compact</div>
<div class="ui-popup ui-picker-popup acpmux-mp" id="model-picker">Models</div>
<div class="acpmux-mp-cascade"><div class="acpmux-mp-sub" id="model-sub">Older</div></div>
<div class="acpmux-changes"><div class="acpmux-file-menu-list" id="file-menu">Open</div></div>
</div>
<div class="ui-positioner"><div class="ui-popup" id="popup">Menu</div></div>
<div class="ui-positioner"><div class="ui-popup ui-context-menu" id="context-menu">Copy</div></div>
<div class="ui-positioner"><div class="ui-popup acpmux-effort-menu" id="effort">High</div></div>
<div class="ui-positioner"><div class="ui-popup acpmux-access-menu" id="access">Full access</div></div>
<div class="ui-positioner"><div class="ui-popup acpmux-chat-menu-popover" id="chat-menu">Rename</div></div>
<div class="ui-positioner"><div class="acpmux-pr-status" id="pr-status">Checks</div></div>
<div class="ui-positioner"><div class="acpmux-summary-popover" id="summary">Summary</div></div>
<div class="ui-positioner"><div class="ui-popup nt-popover" id="new-tab-suggestions">reddit.com</div></div>
${tooltips}`,
    surfaces: [
      "cascade",
      "context-pop",
      "slash",
      "model-picker",
      "model-sub",
      "file-menu",
      "popup",
      "context-menu",
      "effort",
      "access",
      "chat-menu",
      "pr-status",
      "summary",
      // Leo 10-13: the New Tab suggestions showed the page's rows through them on a wallpaper theme.
      "new-tab-suggestions",
      "title-tooltip",
    ],
  };

  const open = async (browser: Browser, fixture: { css: string; body: string }) => {
    const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
    await page.setContent(
      `<!doctype html><html style="${theme}"><head><style>${fixture.css}</style></head><body>${fixture.body}</body></html>`,
    );
    return page;
  };
  const material = (page: Page, id: string) =>
    page.$eval(`#${id}`, (node) => {
      const style = getComputedStyle(node);
      const blur = [style.getPropertyValue("backdrop-filter"), style.getPropertyValue("-webkit-backdrop-filter")];
      return { background: style.backgroundColor, blurred: blur.some((value) => value !== "" && value !== "none") };
    });

  for (const [name, engine] of engines) {
    describe(`popup surfaces in ${name}`, () => {
      let browser: Browser;
      beforeAll(async () => {
        browser = await engine.launch({ headless: true });
      });
      afterAll(async () => browser?.close());

      for (const [where, fixture] of [
        ["pages", pages],
        ["the agent pane", pane],
      ] as const) {
        test(`every menu, popover and tooltip in ${where} is the opaque popup surface, unblurred`, async () => {
          const page = await open(browser, fixture);
          const seen: Record<string, { background: string; blurred: boolean }> = {};
          for (const id of fixture.surfaces) seen[id] = await material(page, id);
          const want = Object.fromEntries(fixture.surfaces.map((id) => [id, { background: POPUP, blurred: false }]));
          expect(seen).toEqual(want);
          await page.close();
        });
      }

      // Leo 10-13 (coherence pass): one elevation for every menu and popover. The New Tab
      // suggestions cast a deeper, darker shadow of their own than the menus opened from the same
      // box, so the two read as different layers.
      test("every menu and popover in the agent pane casts the one popup elevation", async () => {
        const page = await open(browser, pane);
        const look = (id: string) =>
          page.$eval(`#${id}`, (node) => {
            const style = getComputedStyle(node);
            return { border: style.borderTopWidth, radius: style.borderTopLeftRadius, shadow: style.boxShadow };
          });
        const want = await look("context-menu");
        const ids = pane.surfaces.filter((id) => id !== "title-tooltip");
        const seen: Record<string, { border: string; radius: string; shadow: string }> = {};
        for (const id of ids) seen[id] = await look(id);
        expect(seen).toEqual(Object.fromEntries(ids.map((id) => [id, want])));
        await page.close();
      });

      // Coherence pass batch 2: the web popups cast the native popup shadow (PopupStyle.swift), so a
      // menu has the same depth in a page as over the sidebar. The deeper two-layer shadow came with
      // the glass popups (#19008); popups are solid again, and POLISH asks for subtle shadows.
      test("the web popup shadow is the native popup shadow", async () => {
        const swift = fs.readFileSync(
          path.resolve(import.meta.dir, "../../Packages/macOS/CmuxNext/Sources/CmuxNextDesign/PopupStyle.swift"),
          "utf8",
        );
        const value = (name: string) => Number(swift.match(new RegExp(`let ${name}: CGFloat = ([\\d.]+)`))![1]);
        const [offset, blur, alpha] = [value("shadowOffset"), value("shadowBlur"), value("shadowAlpha")];
        const page = await open(browser, pages);
        const shadow = await page.$eval("#menu", (node) => getComputedStyle(node).boxShadow);
        // Black at an alpha serializes as rgba() or, from color-mix(), as color(srgb ...).
        const drops = shadow
          .split(/,(?![^(]*\))/)
          .filter((part) => !part.includes("inset"))
          .map((part) => part.trim().replace(/^rgba\(0, 0, 0, ([\d.]+)\)/, "color(srgb 0 0 0 / $1)"));
        expect(drops).toEqual([`color(srgb 0 0 0 / ${alpha}) 0px ${offset}px ${blur}px 0px`]);
        await page.close();
      });

      test("the web tooltips match the native tooltip", async () => {
        for (const fixture of [pages, pane]) {
          const page = await open(browser, fixture);
          for (const id of fixture === pages ? ["ui-tooltip", "title-tooltip"] : ["title-tooltip"]) {
            const look = await page.$eval(`#${id}`, (node) => {
              const style = getComputedStyle(node);
              return {
                ink: style.color,
                radius: style.borderTopLeftRadius,
                padding: `${style.paddingTop} ${style.paddingLeft}`,
                border: `${style.borderTopWidth} ${style.borderTopStyle} ${style.borderTopColor}`,
                font: `${style.fontSize}/${style.lineHeight}`,
                shadow: style.boxShadow !== "none",
                width: Math.round(node.getBoundingClientRect().width),
              };
            });
            expect({ id, ...look }).toEqual({
              id,
              ink: TEXT,
              radius: "5px",
              padding: "4px 8px",
              border: `1px solid ${SEPARATOR}`,
              font: "11px/14px",
              shadow: true,
              width: 320,
            });
          }
          const hint = await page.$eval("#hint", (node) => getComputedStyle(node).color);
          expect(hint).toBe(SECONDARY);
          await page.close();
        }
      });
    });
  }
});
