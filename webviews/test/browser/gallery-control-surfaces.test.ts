// cmux-web-test-timeout: 900
// l10n-allow-file: browser audit diagnostics, not shipped UI.
import { afterAll, beforeAll, expect, test } from "bun:test";
import path from "node:path";
import { mkdir } from "node:fs/promises";
import { chromium, type Browser } from "playwright";
import { loadEntrySources } from "../../scripts/gallery/entries";
import { requireBrowserLane } from "../support/requireBrowserLane";
import { galleryFrame, warmGalleryFrame } from "../support/galleryFrame";

await requireBrowserLane("gallery-control-surfaces.test.ts", async () => {
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
      selector: '.diff-pill[role="toolbar"]',
      kind: "plate",
      reason: "The standalone floating diff toolbar is its own glass surface, not trailing tools on a row.",
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
  const selected = filter ? cases.filter((c) => filter.split(",").includes(c.id)) : cases;
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
          { browser, timeoutMs: 300_000 },
        ),
      ),
    );
    console.log(`Warmed ${ids.length} gallery entries; auditing controls.`);
  }, 320_000);
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });
  test("every web gallery entry keeps trailing surfaces clear and hover inside its control", async () => {
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
              await page.mouse.move(-10, -10);
              const point = await page.evaluate(
                (i) => (window as unknown as AuditWindow).controlSurfaceAudit.before(i),
                index,
              );
              if (!point) continue;
              await page.mouse.move(point.x, point.y);
              const changes = await page.evaluate(() => (window as unknown as AuditWindow).controlSurfaceAudit.after());
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
      `Gallery control audit: ${visited}/${selected.length} states, ${groups} groups, ${hovered} controls hovered; ${sources.filter(({ entry }) => entry.host === "native").length} native capture descriptors excluded.`,
    );
    expect(failures).toEqual([]);
    expect(groups).toBeGreaterThan(0);
    expect(hovered).toBeGreaterThan(0);
  }, 550_000);
});
