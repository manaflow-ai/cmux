// cmux-web-test-timeout: 300
// Everything clickable in the agent pane shows the pointing hand, in real gallery states (Leo
// 2026-10-21: "why hover over doesnt switch clicky indicator :(" over "Subagent finished: … · 49m
// 38s"; "STOP BUTTON, I HOVER OVER IT, MY CURSOR SHOULD ALSO SEE IT AS CLICKABLE"). Each stage's
// clickable elements are the ones the shared rule names (buttons, links, clickable roles, summaries,
// labels of a choice) and every element React gave an onClick; each one that is drawn and enabled
// must compute a cursor other than the arrow (`default`) or `auto` (the I-beam over text). The
// finished-subagent row, the composer's Stop, the pull request bars, the reply chips, a Files tree
// row, a shortcut row and a Markdown toolbar button are named.
// clickable-cursor.test.ts checks the stylesheets themselves.
//
// Real Chromium from Playwright; CI fails the file when it cannot launch (requireBrowserLane).
// Locally: CMUX_BROWSER_TESTS=1 bun test test/clickable-cursor-gallery.test.ts
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("clickable-cursor-gallery.test.ts", async () => {
  setDefaultTimeout(240_000);
  const webviews = path.resolve(import.meta.dir, "..");
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;

  /** `named` must show the hand; `arrow` must keep the arrow (a disabled choice and its label). */
  type Stage = { entry: string; variant: string; named: Record<string, string>; arrow?: Record<string, string> };
  /** Each stage, and the clickable things in it that must be there (by selector). */
  const STAGES: Stage[] = [
    {
      entry: "agent-pane.subagent-tray",
      variant: "finished-line",
      named: { "Subagent finished row": "button.cv-subagent-done:not(:disabled)" },
    },
    {
      entry: "agent-pane.subagent-tray",
      variant: "several-running",
      named: { "composer Stop": "button.acpmux-cancel", "composer Mic": "button.acpmux-mic" },
    },
    { entry: "agent-pane.transcript", variant: "github-references", named: { "reference chip": "a.cv-chip.is-ref" } },
    { entry: "agent-pane.transcript", variant: "conversation", named: {} },
    { entry: "agent-pane.transcript", variant: "tool-calls", named: {} },
    { entry: "agent-pane.transcript", variant: "thought-row", named: {} },
    { entry: "agent-pane.composer", variant: "queued-actions", named: { "composer Stop": "button.acpmux-cancel" } },
    { entry: "agent-pane.pr-dock", variant: "several", named: { "pull request bar": "a.acpmux-pr-dock__bar" } },
    { entry: "agent-pane.url-chip", variant: "pull-request", named: { "pull request chip": "a.cv-chip" } },
    { entry: "agent-pane.path-chip", variant: "file", named: { "path chip": "button.cv-chip.is-path" } },
    // A file tree row selects on press and opens on double-click (ui/Tree's treeitem rows).
    { entry: "pages.files", variant: "expanded", named: { "file tree row": '.files-row[role="treeitem"]' } },
    // The Markdown page's toolbar: Back, Rich/Source and Aa (ui/Toolbar's .ui-button).
    {
      entry: "pages.markdown",
      variant: "readme",
      named: { "Markdown toolbar button": "button.ui-toolbar-button:not(:disabled)" },
    },
    // Cloud's create sheet: a size the plan has is a choice; a locked size is a disabled radio in
    // a label, and the label and its text keep the arrow.
    {
      entry: "pages.cloud",
      variant: "creating",
      named: { "size choice": ".cloud-size-choice:not(.unavailable)" },
      arrow: {
        "locked size choice": ".cloud-size-choice.unavailable",
        "locked size choice text": ".cloud-size-choice.unavailable .cloud-size-name",
      },
    },
    // A shortcut row selects on click.
    { entry: "pages.keybindings", variant: "normal", named: { "shortcut row": "tr.keys-row" } },
  ];

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(vite, [...new Set(STAGES.map((stage) => stage.entry))], { browser });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  for (const stage of STAGES)
    test(`${stage.entry} ${stage.variant}: every clickable thing shows the pointing hand`, async () => {
      const port = (vite!.httpServer!.address() as { port: number }).port;
      const page = await browser!.newPage({ viewport: { width: 1000, height: 760 } });
      await page.goto(`http://127.0.0.1:${port}${galleryFrame(stage.entry, { variant: stage.variant, width: 1000 })}`);
      await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
        timeout: 120_000,
      });
      const arrow = stage.arrow ?? {};
      for (const selector of [...Object.values(stage.named), ...Object.values(arrow)])
        await page.locator(selector).first().waitFor();
      const result = await page.evaluate(
        ({ named, arrow }) => {
          const CLICKABLE =
            'button, a[href], [role="button"], [role="link"], [role="menuitem"], [role="menuitemcheckbox"], [role="menuitemradio"], [role="tab"], [role="option"], [role="treeitem"], [role="switch"], [role="checkbox"], [role="radio"], summary, label[for], label:has(input[type="checkbox"], input[type="radio"]), select, input:is([type="checkbox"], [type="radio"], [type="button"], [type="submit"], [type="reset"], [type="color"], [type="file"])';
          const reactClick = (element: Element) => {
            const key = Object.keys(element).find((name) => name.startsWith("__reactProps$"));
            const props = key ? (element as unknown as Record<string, { onClick?: unknown }>)[key] : undefined;
            return typeof props?.onClick === "function";
          };
          const drawn = (element: Element) => {
            const box = element.getBoundingClientRect();
            const style = getComputedStyle(element);
            return box.width > 0 && box.height > 0 && style.visibility === "visible" && style.pointerEvents !== "none";
          };
          const describe = (element: Element) =>
            `${element.tagName.toLowerCase()}${element.className && typeof element.className === "string" ? "." + element.className.trim().split(/\s+/).join(".") : ""}${element.getAttribute("aria-label") ? `[${element.getAttribute("aria-label")}]` : ""}`;
          const all = [...document.querySelectorAll("*")].filter(
            (element) => element.matches(CLICKABLE) || reactClick(element),
          );
          // A label of a disabled control is disabled too.
          const labelOfDisabled = (element: Element) =>
            element instanceof HTMLLabelElement && (element.control as HTMLInputElement | null)?.disabled === true;
          // Disabled as the browser has it: the element itself (a disabled fieldset's first legend
          // stays enabled; a link in one still opens), inside a disabled button, aria-disabled or inert.
          const disabled = (element: Element) =>
            element.matches(":disabled") ||
            element.closest('button:disabled, [aria-disabled="true"], [inert]') !== null ||
            labelOfDisabled(element);
          const checked = all.filter((element) => drawn(element) && !disabled(element));
          const arrows = checked
            .map((element) => ({ element, cursor: getComputedStyle(element).cursor }))
            .filter(({ cursor }) => cursor === "default" || cursor === "auto")
            .map(({ element, cursor }) => `${describe(element)}: ${cursor}`);
          const cursors = (map: Record<string, string>) =>
            Object.fromEntries(
              Object.entries(map).map(([name, selector]) => {
                const element = document.querySelector(selector);
                return [name, element ? getComputedStyle(element).cursor : "missing"];
              }),
            );
          return {
            count: checked.length,
            arrows: [...new Set(arrows)],
            named: cursors(named),
            arrow: cursors(arrow),
          };
        },
        { named: stage.named, arrow },
      );
      await page.close();
      expect(result.count).toBeGreaterThan(0);
      expect(result.named).toEqual(Object.fromEntries(Object.keys(stage.named).map((name) => [name, "pointer"])));
      expect(result.arrow).toEqual(Object.fromEntries(Object.keys(arrow).map((name) => [name, "default"])));
      expect(result.arrows).toEqual([]);
    });
});
