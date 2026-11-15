// l10n-allow-file: browser audit diagnostics, not shipped UI.
// The gallery control-surface audit over every web gallery entry, split into parts
// (browser/gallery-control-surfaces-N.test.ts): a control's trailing group paints no plate of its
// own, and a control's hover never lights an ancestor outside it.
//
// Why parts: one file for all 372 entries warmed for about 270 s and audited for about 240 s alone
// (runs 41601401847, 41601405383). Beside the other browser files on a shard it took about 740 s,
// ran out of its 380 s audit budget, and its alone retry took another 683 s: about 24 minutes of
// shard 1's 28 to 33 (react-apps-check on #40611, 2026-11-10). Each part warms and audits only
// every `parts`-th entry, so no part comes near the old file's time, and the duration split spreads
// the parts over the shards. Every entry is still audited exactly once.
import { afterAll, beforeAll, expect, test } from "bun:test";
import path from "node:path";
import { mkdir } from "node:fs/promises";
import { chromium, type Browser } from "playwright";
import { loadEntrySources } from "../../scripts/gallery/entries";
import { galleryFrame, warmGalleryFrame } from "./galleryFrame";

export type GalleryControlPart = {
  /** One-based. */
  part: number;
  parts: number;
};

/** Call inside requireBrowserLane, from the part's own file (the runner reads that file for the lane). */
export async function galleryControlSurfaces({ part, parts }: GalleryControlPart): Promise<void> {
  // Every web entry's default variant plus the shared-row cases. Native entries are capture
  // descriptors, not DOM surfaces, so the browser cannot inspect their paint.
  const EXTRA_VARIANTS: Record<string, string[]> = {
    "agent-pane.summary-card": ["shared-tab-row", "preview-tab-row"],
  };
  // Exact selectors only: a menu surface may paint, but that never exempts its action descendants.
  const ALLOW: { selector: string; kind: "plate" | "hover"; control?: string; reason: string }[] = [
    { selector: ".pw-row", kind: "hover", control: ".pw-row-button", reason: "fixed by #27086" },
    {
      selector: ".acpmux-running-tray .acpmux-agent-line:has(> .acpmux-agent-line__button:enabled)",
      kind: "hover",
      // Stop sits in the line, or in its fixed stop column (#27263's `__stop-slot`).
      control:
        ".acpmux-agent-line > :is(.cv-subagent__stop, .acpmux-session-info-stop), " +
        ".acpmux-agent-line > .acpmux-agent-line__stop-slot > :is(.cv-subagent__stop, .acpmux-session-info-stop)",
      reason: "The tray line is one full-width control; its embedded Stop shares its wash, never a second box.",
    },
    {
      selector: ".acpmux-edited-head[data-header-toggle]",
      kind: "hover",
      control: ".acpmux-edited-head[data-header-toggle] > .acpmux-edited-toggle",
      reason:
        "The edits card's header is one full-width toggle (headerToggle.ts); its chevron is that toggle's keyboard control and shares its wash, never a second box.",
    },
    {
      selector: ".cv-turn-retry",
      kind: "hover",
      control: ".cv-turn-retry > .cv-iconbtn",
      reason:
        "A reply footer's Retry and its model switch are one split control (TurnRows.tsx TurnFooter); both halves share one pill, never a box around the row.",
    },
    {
      selector: ".cv-message-retry",
      kind: "hover",
      control: ".cv-message-retry > .cv-iconbtn",
      reason:
        "A prompt's Retry and its model switch are the same split control as a reply footer's (MessageActions.tsx, conversation.css .cv-message-retry); both halves share one pill, never a box around the row.",
    },
    {
      selector: ".hc-msg",
      kind: "hover",
      control: ".hc-msg button",
      reason:
        "A Home channel message is one row that washes whenever the pointer is over it (styles.css .hc-msg:hover), the channel list's row hover; a button in it (a code block's Copy, its actions) shares that wash, never a box of its own.",
    },
    {
      selector: '.diff-pill[role="toolbar"]',
      kind: "plate",
      reason: "The standalone floating diff toolbar is its own glass surface, not trailing tools on a row.",
    },
    {
      selector: ".cv-table-tools.ui-glass",
      kind: "plate",
      reason:
        "A reply table's Open and Copy float as one glass pill on the table's own corner, over its header or the line above (TableBlock.tsx); the glass keeps them legible over text.",
    },
  ];
  type Finding = { kind: string; selector: string; detail: string };

  /** Installed in real gallery frames: geometry and paint come from the browser, not source rules. */
  function installAudit(allow: typeof ALLOW) {
    const canvas = document.createElement("canvas");
    canvas.width = canvas.height = 1;
    const ctx = canvas.getContext("2d", { willReadFrequently: true })!;
    const hasColor = (color: string) => {
      ctx.clearRect(0, 0, 1, 1);
      ctx.fillStyle = color;
      ctx.fillRect(0, 0, 1, 1);
      return ctx.getImageData(0, 0, 1, 1).data[3]! > 0;
    };
    const label = (el: Element) => `${el.tagName.toLowerCase()}${[...el.classList].map((c) => `.${c}`).join("")}`;
    const visible = (el: Element) => {
      const rect = el.getBoundingClientRect(),
        css = getComputedStyle(el);
      return rect.width > 0 && rect.height > 0 && css.visibility !== "hidden" && css.display !== "none";
    };
    const small = (el: Element) => {
      const rect = el.getBoundingClientRect();
      return (
        visible(el) &&
        rect.width <= 40 &&
        rect.height <= 40 &&
        !!(el.querySelector("svg, img, [data-icon]") || el.hasAttribute("aria-label") || el.hasAttribute("title"))
      );
    };
    const controls = [...document.querySelectorAll<HTMLElement>('button, [role="button"], a[aria-label]')].filter(
      small,
    );
    const paint = (el: Element) => {
      const s = getComputedStyle(el);
      const colors = s.boxShadow.match(/(?:rgba?|color|lab|oklab|lch|oklch)\([^)]*\)/g) ?? [];
      const border = ["Top", "Right", "Bottom", "Left"].some((side) => {
        const css = s as unknown as Record<string, string>;
        return (
          Number.parseFloat(css[`border${side}Width`]!) > 0 &&
          !["none", "hidden"].includes(css[`border${side}Style`]!) &&
          hasColor(css[`border${side}Color`]!)
        );
      });
      return {
        background:
          hasColor(s.backgroundColor) || s.backgroundImage !== "none"
            ? `${s.backgroundColor} ${s.backgroundImage}`
            : "",
        border: border ? `${s.borderTop} ${s.borderRight} ${s.borderBottom} ${s.borderLeft}` : "",
        shadow: s.boxShadow !== "none" && (colors.length === 0 || colors.some(hasColor)) ? s.boxShadow : "",
      };
    };
    const exempt = (el: Element, kind: "plate" | "hover", control?: Element) =>
      allow.find((a) => a.kind === kind && el.matches(a.selector) && (!a.control || control?.matches(a.control)));
    const contains = (outer: DOMRect, inner: DOMRect) =>
      inner.left >= outer.left - 2 &&
      inner.top >= outer.top - 2 &&
      inner.right <= outer.right + 2 &&
      inner.bottom <= outer.bottom + 2;
    const findings: Finding[] = [];
    const groups = new Set<Element>();
    for (const control of controls) {
      const parent = control.parentElement;
      if (!parent || parent.matches('button, [role="button"], a')) continue;
      const children = [...parent.children];
      const named = [...parent.classList].some((name) => /(?:^|[-_])(actions|tools|trailing)(?:$|[-_])/.test(name));
      const cluster = children.length > 1 && children.every((child) => controls.includes(child as HTMLElement));
      if (named || cluster) groups.add(parent);
    }
    for (const group of groups) {
      const p = paint(group);
      if (Object.values(p).some(Boolean) && !exempt(group, "plate"))
        findings.push({ kind: "plate", selector: label(group), detail: JSON.stringify(p) });
    }
    // A sibling pane's fill is also a plate when it paints into the shared native row.
    for (const shell of document.querySelectorAll(".acpmux-shell[data-tab-row]")) {
      const header = shell.querySelector(".acpmux-header[data-tab-row]");
      if (!header) continue;
      const headerRect = header.getBoundingClientRect();
      // The shared native tab row spans the shell, even on the broken version whose web header
      // was narrowed by the Summary column. Use its full offered width for the intersection.
      const shellRect = shell.getBoundingClientRect();
      const row = { left: shellRect.left, right: shellRect.right, top: headerRect.top, bottom: headerRect.bottom };
      for (const sibling of shell.children) {
        if (sibling.contains(header) || !visible(sibling)) continue;
        const rect = sibling.getBoundingClientRect();
        if (
          rect.left < row.right &&
          rect.right > row.left &&
          rect.top < row.bottom &&
          rect.bottom > row.top &&
          Object.values(paint(sibling)).some(Boolean)
        )
          findings.push({
            kind: "overlap",
            selector: label(sibling),
            detail: `pane top ${rect.top} overlaps tab row bottom ${row.bottom}`,
          });
      }
    }
    const snapshots = new Map<Element, ReturnType<typeof paint>>();
    let current: HTMLElement | undefined;
    const audit = {
      findings,
      controls: controls.length,
      groups: groups.size,
      before(index: number) {
        current = controls[index];
        snapshots.clear();
        if (!current?.isConnected || !visible(current)) return null;
        current.scrollIntoView({ block: "nearest", inline: "nearest", behavior: "instant" });
        const rect = current.getBoundingClientRect();
        const x = Math.max(0, rect.left) + Math.min(rect.width, innerWidth - Math.max(0, rect.left)) / 2;
        const y = Math.max(0, rect.top) + Math.min(rect.height, innerHeight - Math.max(0, rect.top)) / 2;
        if (x < 0 || y < 0 || x >= innerWidth || y >= innerHeight) return null;
        const hit = document.elementFromPoint(x, y);
        if (!hit || !current.contains(hit)) return null; // covered by a menu, or outside its scrollport
        for (let el: Element | null = current; el && el !== document.documentElement; el = el.parentElement)
          snapshots.set(el, paint(el));
        return { x, y, selector: label(current) };
      },
      after() {
        if (!current?.isConnected || !current.matches(":hover")) return [];
        const bounds = current.getBoundingClientRect(),
          result: Finding[] = [];
        for (const [el, before] of snapshots) {
          const after = paint(el);
          if (JSON.stringify(after) === JSON.stringify(before) || !Object.values(after).some(Boolean)) continue;
          if (!contains(bounds, el.getBoundingClientRect()) && !exempt(el, "hover", current))
            result.push({
              kind: "hover",
              selector: label(el),
              detail: `${label(current)} highlights ancestor outside its 2px inset: ${JSON.stringify(after)}`,
            });
        }
        return result;
      },
    };
    (window as unknown as AuditWindow).controlSurfaceAudit = audit;
    return audit;
  }

  type AuditWindow = Window & { controlSurfaceAudit: ReturnType<typeof installAudit> };
  const root = path.resolve(import.meta.dir, "../..");
  const sources = await loadEntrySources();
  const cases = sources
    .filter(({ entry }) => entry.host !== "native")
    .flatMap(({ entry }) =>
      [...new Set([Object.keys(entry.variants)[0]!, ...(EXTRA_VARIANTS[entry.id] ?? [])])].map((variant) => ({
        id: entry.id,
        variant,
        height: entry.height ?? 720,
      })),
    );
  // Local red/green reproduction can select the known regressions. CI always walks every entry.
  const filter = process.env.GALLERY_CONTROL_ENTRIES;
  if (process.env.CI && filter) throw new Error("CI cannot filter the gallery control guard");
  // A filtered local run audits its entries in part 1; every part of CI's run takes every
  // `parts`-th entry.
  const selected = filter
    ? part === 1
      ? cases.filter((c) => filter.split(",").includes(c.id))
      : []
    : cases.filter((_, index) => index % parts === part - 1);
  if (selected.length === 0 && filter) {
    test.skip(`gallery control audit part ${part} of ${parts}: GALLERY_CONTROL_ENTRIES runs in part 1`, () => {});
    return;
  }
  // Both phases share the part's limit (its file's header). Measured on Linux CI with 372 web
  // entries in one file (runs 41601401847, 41601405383): the warm-up took 269 s with 4 workers and
  // 267 s with 8 (Vite's transforms bound it, not the browser), and the audit 240 s; the old 300 s
  // warm-up budget left ~10% and went red (run 41597839583). A part warms and audits a quarter of
  // the entries, but the modules they share still compile once per part, so its warm-up keeps more
  // than a quarter of the old budget: these keep ~1.3x over a quarter of the contended 740 s run.
  const WARM_MS = 360_000;
  const AUDIT_MS = 240_000;
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>>;
  let browser: Browser;
  beforeAll(async () => {
    vite = await createServer({
      root,
      configFile: path.join(root, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1" },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch();
    // Discover every entry's dependencies before parallel audits: Vite otherwise reloads
    // unrelated pages when a later entry adds an optimized dependency.
    const ids = [...new Set(selected.map(({ id }) => id))];
    await Promise.all(
      Array.from({ length: 4 }, (_, worker) =>
        warmGalleryFrame(
          vite,
          ids.filter((_, index) => index % 4 === worker),
          { browser, timeoutMs: WARM_MS },
        ),
      ),
    );
    console.log(`Warmed ${ids.length} gallery entries; auditing controls.`);
  }, WARM_MS + 20_000);
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });
  test(
    `every web gallery entry keeps trailing surfaces clear and hover inside its control (part ${part} of ${parts})`,
    async () => {
      expect(selected.length).toBeGreaterThan(0);
      const port = (vite.httpServer!.address() as { port: number }).port;
      const failures: string[] = [],
        pending = [...selected];
      let visited = 0,
        groups = 0,
        hovered = 0;
      await Promise.all(
        Array.from({ length: 4 }, async () => {
          for (let entry = pending.shift(); entry; entry = pending.shift()) {
            // A fresh context prevents one gallery's saved settings/draft from leaking into another.
            const page = await browser.newPage({ viewport: { width: 1000, height: 800 }, reducedMotion: "reduce" });
            page.setDefaultTimeout(30_000);
            const name = `${entry.id}/${entry.variant}`;
            try {
              await page.setViewportSize({ width: 1000, height: Math.min(1200, entry.height) });
              await page.goto(
                `http://127.0.0.1:${port}${galleryFrame(entry.id, { variant: entry.variant, reducedMotion: "true", colorScheme: process.env.GALLERY_CONTROL_THEME })}`,
              );
              await page.waitForFunction(() => document.documentElement.dataset.galleryReady);
              if ((await page.locator("html").getAttribute("data-gallery-ready")) !== "1")
                throw new Error((await page.locator("body").innerText()).slice(0, 400));
              await page.addStyleTag({
                content: "*, *::before, *::after { transition: none !important; animation: none !important; }",
              });
              await page.mouse.move(-10, -10);
              await page.evaluate(installAudit, ALLOW);
              const baseline = await page.evaluate(() => ({
                findings: (window as unknown as AuditWindow).controlSurfaceAudit.findings,
                groups: (window as unknown as AuditWindow).controlSurfaceAudit.groups,
                controls: (window as unknown as AuditWindow).controlSurfaceAudit.controls,
              }));
              groups += baseline.groups;
              failures.push(...baseline.findings.map((f) => `${name}: ${f.kind} ${f.selector}: ${f.detail}`));
              for (let index = 0; index < baseline.controls; index++) {
                // FOCUS-RING: a stage that focused a field from its play shows that field's ring until
                // the pointer moves past its slop (ui/focusModality.ts). The pointer is in use before
                // the baseline (a move inside the page; one outside it fires no event), so the hover
                // below measures the hover alone, not the ring leaving.
                await page.mouse.move(1, 1);
                await page.mouse.move(1, 20);
                await page.mouse.move(-10, -10);
                const point = await page.evaluate(
                  (i) => (window as unknown as AuditWindow).controlSurfaceAudit.before(i),
                  index,
                );
                if (!point) continue;
                await page.mouse.move(point.x, point.y);
                const changes = await page.evaluate(() =>
                  (window as unknown as AuditWindow).controlSurfaceAudit.after(),
                );
                const capture = process.env.GALLERY_CONTROL_CAPTURE_DIR;
                const selectors = process.env.GALLERY_CONTROL_CAPTURE_SELECTORS?.split(",") ?? [];
                if (capture && selectors.some((selector) => point.selector.includes(selector))) {
                  await mkdir(capture, { recursive: true });
                  await page.screenshot({ path: path.join(capture, `${entry.id}-${index}.png`) });
                }
                hovered++;
                failures.push(...changes.map((f) => `${name}: ${f.kind} ${f.selector}: ${f.detail}`));
              }
              visited++;
            } catch (error) {
              failures.push(`${name}: load/audit error ${String(error).slice(0, 500)}`);
            } finally {
              await page.close();
            }
          }
        }),
      );
      console.log(
        `Gallery control audit, part ${part} of ${parts}: ${visited}/${selected.length} states, ${groups} groups, ${hovered} controls hovered; ${sources.filter(({ entry }) => entry.host === "native").length} native capture descriptors excluded.`,
      );
      expect(failures).toEqual([]);
      expect(groups).toBeGreaterThan(0);
      expect(hovered).toBeGreaterThan(0);
    },
    AUDIT_MS,
  );
}
