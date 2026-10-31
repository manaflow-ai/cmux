// Leo, 2026-10-12: popovers, menus and tooltips were glass at 92% with a blur, so the text under
// them showed through (the New Tab folder popover over the Chats list read as text on text). They
// became the solid popup surface, `--surface-popup`: the host's `--cmux-popup-surface`, the same
// opaque fill as the native overlays (`Palette.popupSurface`), with no backdrop blur. Since the
// liquid glass (2026-10-20, Leo: popups are glass, never opaque) every menu, popover and picker is
// `.ui-glass` (ui/popupSurface.css): translucent and frosted in every glass mode, Plain included;
// only under Reduce Transparency is it that solid popup surface again, unblurred. Floating surfaces
// that are not popups keep the solid surface. The two
// web tooltips (Base UI's `.ui-tooltip`, the title tooltip) match the native tooltip: primary ink,
// 5 px radius, 4×8 padding, a separator hairline and the caption font; since 2026-10-14 they are
// frosted glass instead (tooltip-surface.test.ts).
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
      "ui/glass/glass.css",
      "pages/shared/pageBase.css",
      "ui/popupSurface.css",
      "ui/ui.css",
      "icon-picker/styles.css",
      "pages/markdown/styles.css",
      "pages/home-channels/styles.css",
      "pages/home-channels/ledger.css",
      "pages/editor/styles.css",
    ),
    body: `<div class="ui-positioner"><div class="ui-popup ui-glass" id="menu">Menu</div></div>
${tooltips}
<div class="ui-positioner"><div class="page-menu ui-popup ui-glass" id="page-menu">Sort</div></div>
<div class="ui-glass icon-bar-pill" id="icon-bar-pill">Icons</div>
<div class="md-link-bubble" id="md-link-bubble">https://example.com</div>
<div class="ui-popup ui-glass ui-popover md-link-popover" id="md-link-popover">Edit link</div>
<div class="hc-msg-toolbar" id="hc-msg-toolbar">React</div>
<div class="lg-palette" id="lg-palette">Search conversations</div>
<div class="lg-form" id="lg-form">New message</div>
<div id="editor-widget" style="background: var(--cmux-editor-widget-background)">Suggest</div>`,
    // Tooltips are frosted glass (tooltip-surface.test.ts).
    // The markdown link editor is a ui/Popover: glass, like the menus. The History page menu
    // (pages/shared/PageMenu.tsx) is the menu glass too (Leo 2026-10-21: "STOP DOING SOLID. WE HAVE
    // GLASS, SO JUST USE GLASS.").
    glass: ["menu", "page-menu", "icon-bar-pill", "md-link-popover"],
    surfaces: [
      "menu",
      "page-menu",
      "icon-bar-pill",
      "md-link-bubble",
      "md-link-popover",
      "hc-msg-toolbar",
      "lg-palette",
      "lg-form",
      "editor-widget",
    ],
  };
  // The agent pane: desktop.css, the popup surface, then the pane's sheets (build-agent-pane-web.sh).
  const pane = {
    css: read(
      "pages/shared/desktop.css",
      "ui/glass/glass.css",
      "ui/popupSurface.css",
      "agent-session/acpmux/styles.css",
      "agent-session/acpmux/changes/changes.css",
      "agent-session/acpmux/composerControls.css",
      "agent-session/acpmux/composerLocation.css",
      "agent-session/acpmux/composerStates.css",
      "agent-session/acpmux/modelPicker.css",
      "agent-session/acpmux/summary/summary.css",
      "agent-session/acpmux/header/header.css",
      "agent-session/acpmux/newtab/screen.css",
      "agent-session/acpmux/needsYou/needsYou.css",
      "agent-session/acpmux/subagents/subagents.css",
      "agent-session/acpmux/addProject.css",
    ),
    body: `<div class="acpmux-shell">
<div class="ui-popup ui-glass acpmux-menu" id="cascade">Model</div>
<div class="ui-popup ui-glass acpmux-slash-menu" id="slash">/compact</div>
<div class="acpmux-composer"><div class="ui-popup ui-glass acpmux-slash-menu acpmux-mention-menu" id="composer-menu">@file</div></div>
<div class="ui-popup ui-glass ui-picker-popup acpmux-mp" id="model-picker">Models</div>
<div class="acpmux-changes"><div class="ui-popup ui-glass acpmux-file-menu-list" id="file-menu">Open</div></div>
</div>
<div class="ui-positioner"><div class="ui-popup ui-glass" id="popup">Menu</div></div>
<div class="ui-positioner"><div class="ui-popup ui-glass ui-context-menu" id="context-menu">Copy</div></div>
<div class="ui-positioner"><div class="ui-popup ui-glass acpmux-effort-menu" id="effort">High</div></div>
<div class="ui-positioner"><div class="ui-popup ui-glass acpmux-access-menu" id="access">Full access</div></div>
<div class="ui-positioner"><div class="ui-popup ui-glass acpmux-chat-menu-popover" id="chat-menu">Rename</div></div>
<div class="ui-positioner"><div class="ui-popup ui-glass ui-popover acpmux-pr-status" id="pr-status">Checks</div></div>
<div class="acpmux-shell"><div class="ui-glass ui-glass-floats acpmux-summary-card" data-placement="popover" id="summary">Summary</div></div>
<div class="ui-positioner"><div class="ui-popup ui-glass ui-popover nt-popover" id="new-tab-suggestions">reddit.com</div></div>
<div class="ui-positioner"><div class="ui-popup ui-glass ui-popover acpmux-needs-you" id="needs-you">Needs you</div></div>
<div class="acpmux-shell"><dialog open class="ui-popup ui-glass acpmux-agents-list" id="agents-list">Agents</dialog></div>
<dialog open class="ui-glass acpmux-add-project-dialog" id="add-project">Add project</dialog>
${tooltips}`,
    glass: [
      "cascade",
      "slash",
      // The slash, mention and access menus open inside the composer: never its solid card tint.
      "composer-menu",
      "model-picker",
      "file-menu",
      "popup",
      "context-menu",
      "effort",
      "access",
      "chat-menu",
      "pr-status",
      "new-tab-suggestions",
      "needs-you",
      "agents-list",
      // The Summary popover (Outputs, Subagents, Sources, Background tasks) floats over the chat
      // (Leo 2026-10-30: "I don't like the non-glassness").
      "summary",
      // A dialog, not a popup (no popup elevation), but glass all the same.
      "add-project",
    ],
    surfaces: [
      "cascade",
      "slash",
      "composer-menu",
      "model-picker",
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
      "needs-you",
      "agents-list",
    ],
  };

  const open = async (browser: Browser, fixture: { css: string; body: string }, root = "") => {
    const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
    await page.setContent(
      `<!doctype html><html ${root} style="${theme}"><head><style>${fixture.css}</style></head><body>${fixture.body}</body></html>`,
    );
    return page;
  };
  /** An rgb(), rgba() or color(srgb ...) background's alpha. */
  const alpha = (color: string) => {
    const slash = color.match(/\/\s*([\d.]+)\)$/);
    if (slash) return Number(slash[1]);
    const rgba = color.match(/^rgba\([^)]*,\s*([\d.]+)\)$/);
    return rgba ? Number(rgba[1]) : 1;
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
        for (const [mode, root] of [
          ["no still yet", undefined],
          ["the lens", "data-glass-lens"],
          ["Plain glass", 'data-glass="plain" data-glass-lens'],
        ] as const) {
          test(`under ${mode} every menu, popover and picker in ${where} is glass: translucent and frosted, never opaque`, async () => {
            const page = await open(browser, fixture, root);
            const seen: Record<string, { translucent: boolean; blurred: boolean }> = {};
            for (const id of fixture.glass) {
              const { background, blurred } = await material(page, id);
              seen[id] = { translucent: alpha(background) < 1, blurred };
            }
            const want = Object.fromEntries(fixture.glass.map((id) => [id, { translucent: true, blurred: true }]));
            expect(seen).toEqual(want);
            await page.close();
          });
        }

        test(`the other floating surfaces in ${where} keep the opaque popup surface, unblurred`, async () => {
          const page = await open(browser, fixture);
          const solid = fixture.surfaces.filter((id) => !fixture.glass.includes(id));
          const seen: Record<string, { background: string; blurred: boolean }> = {};
          for (const id of solid) seen[id] = await material(page, id);
          expect(seen).toEqual(Object.fromEntries(solid.map((id) => [id, { background: POPUP, blurred: false }])));
          await page.close();
        });

        // Only Reduce Transparency asks for opaque: Plain glass is still glass (Leo: never opaque).
        // Every glass surface takes its documented fallback there (--glass-opaque, ui/glass/glass.css).
        test(`under Reduce Transparency every menu, popover, dialog and tooltip in ${where} is the opaque popup surface, unblurred`, async () => {
          const page = await open(browser, fixture, "data-reduce-transparency");
          const ids = [...new Set([...fixture.surfaces, ...fixture.glass])];
          const seen: Record<string, { background: string; blurred: boolean }> = {};
          for (const id of ids) seen[id] = await material(page, id);
          const want = Object.fromEntries(ids.map((id) => [id, { background: POPUP, blurred: false }]));
          expect(seen).toEqual(want);
          await page.close();
        });
      }

      // Leo 10-13 (coherence pass): one elevation for every menu and popover. The New Tab
      // suggestions cast a deeper, darker shadow of their own than the menus opened from the same
      // box, so the two read as different layers.
      // Under Plain glass a glass popup's rim is the popup hairline: the same layers as the solid
      // surfaces' popup shadow, the inset hairline after the drop instead of before it.
      test("every menu and popover in the agent pane casts the one popup elevation", async () => {
        const page = await open(browser, pane, 'data-glass="plain"');
        const look = (id: string) =>
          page.$eval(`#${id}`, (node) => {
            const style = getComputedStyle(node);
            const shadow = style.boxShadow
              .split(/,(?![^(]*\))/)
              .map((layer) => layer.trim())
              .sort()
              .join(", ");
            return { border: style.borderTopWidth, radius: style.borderTopLeftRadius, shadow };
          });
        const want = await look("context-menu");
        const ids = pane.surfaces;
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
        // The raised step of the shared scale (`elevation2`; subtle-elevation.test.ts).
        const raised = swift.match(
          /static let elevation2 = Elevation\(offset: ([\d.]+), blur: ([\d.]+), alpha: ([\d.]+)\)/,
        )!;
        const [offset, blur, alpha] = raised.slice(1, 4).map(Number);
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
