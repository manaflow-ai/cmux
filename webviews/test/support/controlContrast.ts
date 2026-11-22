// l10n-allow-file: browser audit diagnostics, not shipped UI.
// The control contrast audit over every web gallery entry, split into parts
// (control-contrast-N.test.ts). User 2026-11-20: "we should do audit of all surfaces like this to
// make sure all buttons have proper contrasts in all themes/modes".
//
// Every web entry's first variant renders in the gallery's component frame under each SCHEME: the
// app's default dark and light themes, a light theme with Increase Contrast, a see-through window over
// a busy picture and over a light one, and two terminal-tinted themes with their own and a named
// accent. In the default dark and light schemes each control is also read hovered and pressed
// (CSS.forcePseudoState on every control at once). Each control's text must reach 4.5:1 (3:1 when
// large), its icons and other marks 3:1, and a disabled control's ink the legible floor of 2.5:1:
// measured on the painted pixels (test/support/controlContrastScan.ts).
//
// A reading under its minimum fails the part unless its control class is in
// test/control-contrast-baseline.txt (a known violation waiting on a fix) and the reading is no worse
// than the floor recorded there: a ratchet, one line per class (`<class> <text|icon> <floor>`), so a
// new failing control or a known one that gets worse fails, and each fix raises or drops a line.
// A class is the control's tag and first classes (`button.ui-button.ui-tabs-trigger`), its label
// without the text. With CONTRAST_AUDIT_OUT (or FAST_CHECKS_OUT) set, each part also writes every
// failing reading, baselined or not, as a table (control-contrast-N.md) and the part's worst reading
// per class as baseline lines (control-contrast-N.baseline.txt).
//
// Shipped themes (Resources/ghostty/themes and Resources/cmux-themes, over 600) are also read, at rest
// with the theme's own accent, on the entries that hold the shared controls (SWEEP_ENTRIES): a theme
// whose palette breaks a token breaks it on these. Every run reads SAMPLED_THEMES of them, spread
// evenly from the darkest background to the lightest; CONTROL_CONTRAST_SWEEP=1 reads all of them
// (about 4,400 more stages, an hour of one browser: an audit run, not every pull request's).
//
// Captures are at 2x, as the app draws on a Retina screen: thin strokes keep full-ink pixels.
//
// Stages load from test/support/galleryStageServer.ts: the run's built gallery when there is one, else a
// Vite dev server. On the dev server each stage loads about 650 unbundled modules from one Vite thread,
// and the 4 vCPU (at times 2) runners these shards moved to on 2026-11-18 made that the bound.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import fs from "node:fs";
import path from "node:path";
import { chromium, type Browser, type CDPSession, type Page } from "playwright";
import { readShippedThemes } from "../../dev-server/galleryHost";
import { loadEntrySources } from "../../scripts/gallery/entries";
import { hideInk, markControls, readControls, type Control, type Reading } from "./controlContrastScan";
import { warmGalleryFrame } from "./galleryFrame";
import { galleryStageServer, type GalleryStageServer } from "./galleryStageServer";
import { requireBrowserLane } from "./requireBrowserLane";
import { launchStageBrowser, type StageBrowser } from "./stageBrowser";

export type ControlContrastPart = {
  /** The part's test file name, for requireBrowserLane. */
  file: string;
  /** One-based. */
  part: number;
  parts: number;
  /** The gallery's dev server config, named in the part's own file so the runner sees a dev server file. */
  viteConfig: string;
};

/** The themes and modes every entry is read in: the gallery's own query keys (src/gallery/env.ts). */
export const SCHEMES: Scheme[] = [
  { name: "dark", query: {}, states: ["rest", "hover", "active"] },
  { name: "light", query: { colorScheme: "light" }, states: ["rest", "hover", "active"] },
  { name: "light-more-contrast", query: { colorScheme: "light", highContrast: "1" }, states: ["rest"] },
  { name: "dark-over-busy-picture", query: { background: "busy" }, states: ["rest"] },
  { name: "light-over-light-picture", query: { colorScheme: "light", background: "light" }, states: ["rest"] },
  { name: "rose-pine-dawn-theme-accent", query: { theme: "Rose Pine Dawn", accent: "theme" }, states: ["rest"] },
  { name: "catppuccin-mocha-yellow-accent", query: { theme: "Catppuccin Mocha", accent: "yellow" }, states: ["rest"] },
];

type State = "rest" | "hover" | "active";
type Scheme = { name: string; query: Record<string, string>; states: State[] };

/**
 * The entries read in every shipped theme: the kit's buttons, menus, dialogs, tabs and switches,
 * Settings' controls and the chat composer, which together draw every shared control look.
 */
export const SWEEP_ENTRIES = [
  "ui.button",
  "ui.menu",
  "ui.dialog",
  "ui.tabs",
  "ui.switch",
  "pages.settings-controls",
  "agent-pane.composer",
] as const;

/** How many shipped themes every run reads. */
export const SAMPLED_THEMES = 24;

const luminance = (hex: string): number => {
  const value = Number.parseInt(hex.slice(1, 7), 16);
  const linear = (c: number) => (c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4);
  return (
    0.2126 * linear(((value >> 16) & 0xff) / 255) +
    0.7152 * linear(((value >> 8) & 0xff) / 255) +
    0.0722 * linear((value & 0xff) / 255)
  );
};

/** One scheme per shipped theme read (every one, or the sample), at rest, with the theme's own accent. */
const sweepSchemes = (every: boolean): Scheme[] => {
  const themes = readShippedThemes();
  const byGround = [...themes].sort(
    (a, b) => luminance(a.background) - luminance(b.background) || a.name.localeCompare(b.name, "en"),
  );
  const picked = every
    ? themes
    : Array.from(
        new Set(
          Array.from(
            { length: SAMPLED_THEMES },
            (_, i) => byGround[Math.round((i * (byGround.length - 1)) / (SAMPLED_THEMES - 1))]!,
          ),
        ),
      );
  return picked.map((theme) => ({
    name: `theme-${theme.name.toLowerCase().replace(/[^a-z0-9]+/g, "-")}`,
    query: { theme: theme.name, accent: "theme" },
    states: ["rest"] as State[],
  }));
};

/** WCAG 2 minimums: body text, large text and marks (icons, borders), and a disabled control's floor. */
export const MINIMUM = { text: 4.5, large: 3, icon: 3, disabled: 2.5 } as const;

type Stage = { entry: string; variant: string; source: string; height: number; scheme: Scheme };
const stageName = (stage: Stage): string => `${stage.entry}/${stage.variant}@${stage.scheme.name}`;

/** One failing reading. */
export type Failure = { key: string; stage: string; state: State; control: Control; reading: Reading; minimum: number };

/** A control's class for the baseline: its label without the text, and the reading's kind. */
export const classKey = (label: string, kind: string): string => `${label.replace(/ ".*$/, "")} ${kind}`;

/** A failing reading's name in the report: `<entry>/<variant>@<scheme>:<state> <kind> <control label>`. */
export const failureKey = (stage: string, state: State, kind: string, label: string): string =>
  `${stage}:${state} ${kind} ${label}`;

const minimumOf = (control: Control, reading: Reading): number =>
  control.disabled
    ? MINIMUM.disabled
    : reading.kind === "icon"
      ? MINIMUM.icon
      : control.large
        ? MINIMUM.large
        : MINIMUM.text;

export async function controlContrast({ file, part, parts, viteConfig }: ControlContrastPart): Promise<void> {
  await requireBrowserLane(file, async () => {
    setDefaultTimeout(600_000);
    const webviews = path.resolve(import.meta.dir, "../..");
    const baselineFile = path.join(webviews, "test/control-contrast-baseline.txt");
    const baseline = new Map(
      fs
        .readFileSync(baselineFile, "utf8")
        .split("\n")
        .map((line) => line.replace(/\s+#.*$/, "").trim())
        .filter((line) => line && !line.startsWith("#"))
        .map((line) => {
          const [, key, floor] = /^(.*) (\d+(?:\.\d+)?)$/.exec(line) ?? [];
          if (!key || !floor) throw new Error(`control-contrast-baseline.txt: no floor on ${JSON.stringify(line)}`);
          return [key, Number(floor)] as const;
        }),
    );
    const sweep = sweepSchemes(process.env.CONTROL_CONTRAST_SWEEP === "1");
    const sweepEntries = new Set<string>(SWEEP_ENTRIES);
    const sources = (await loadEntrySources()).filter(({ entry }) => entry.host !== "native");
    const missing = SWEEP_ENTRIES.filter((id) => !sources.some(({ entry }) => entry.id === id));
    if (missing.length) throw new Error(`control contrast: sweep entries are gone: ${missing.join(", ")}`);
    if (readShippedThemes().length < 500) throw new Error("control contrast: fewer than 500 shipped themes were read");
    const everyStage: Stage[] = sources
      .flatMap(({ entry, path: source }) =>
        (sweepEntries.has(entry.id) ? [...SCHEMES, ...sweep] : SCHEMES).map((scheme) => ({
          entry: entry.id,
          variant: Object.keys(entry.variants)[0]!,
          source,
          height: entry.height ?? 720,
          scheme,
        })),
      )
      .sort((a, b) => stageName(a).localeCompare(stageName(b)));
    // Local red/green runs may pick entries (CONTROL_CONTRAST_ENTRIES=a,b); CI always reads every one.
    const filter = process.env.CONTROL_CONTRAST_ENTRIES?.split(",").filter(Boolean);
    if (process.env.CI && filter?.length && !process.env.CONTROL_CONTRAST_ALLOW_FILTER)
      throw new Error("CI cannot filter the control contrast audit");
    const stages = filter?.length
      ? part === 1
        ? everyStage.filter((stage) => filter.includes(stage.entry))
        : []
      : everyStage.filter((_, index) => index % parts === part - 1);
    if (stages.length === 0) {
      test.skip(`control contrast part ${part} of ${parts}: CONTROL_CONTRAST_ENTRIES runs in part 1`, () => {});
      return;
    }

    // The stages' server: the run's gallery build when it made one, else the dev server (test/support/galleryStageServer.ts).
    let stageServer: GalleryStageServer | undefined;
    let shared: StageBrowser<Browser, Page> | undefined;
    beforeAll(async () => {
      shared = await launchStageBrowser<Browser, Page>({
        launch: () => chromium.launch({ headless: true }),
        open: (browser) =>
          browser.newPage({ viewport: { width: 760, height: 900 }, deviceScaleFactor: 2, reducedMotion: "reduce" }),
      });
      const first = stages[0]!;
      stageServer = await galleryStageServer({
        configFile: path.join(webviews, viteConfig),
        warm: (vite) =>
          warmGalleryFrame(vite, first.entry, {
            browser: shared!.browser,
            params: { variant: first.variant, frame: "component", ...first.scheme.query },
          }),
      });
    });
    afterAll(async () => {
      await shared?.close();
      await stageServer?.close();
    });

    type Scanned = { stage: string; controls: number; failures: Failure[] } | { stage: string; error: string };

    /** Forces `state` on every marked control (none for rest), through the DevTools CSS domain. */
    const force = async (cdp: CDPSession, state: State): Promise<void> => {
      const { root } = await cdp.send("DOM.getDocument", { depth: 0 });
      const { nodeIds } = await cdp.send("DOM.querySelectorAll", {
        nodeId: root.nodeId,
        selector: "[data-contrast-audit]",
      });
      const forced = state === "rest" ? [] : state === "active" ? ["hover", "active"] : ["hover"];
      await Promise.all(
        nodeIds.map((nodeId) => cdp.send("CSS.forcePseudoState", { nodeId, forcedPseudoClasses: forced })),
      );
    };
    const settle = (page: Page) =>
      page.evaluate(
        () => new Promise<void>((resolve) => requestAnimationFrame(() => requestAnimationFrame(() => resolve()))),
      );
    const capture = async (page: Page): Promise<string> =>
      `data:image/png;base64,${(await page.screenshot({ type: "png", animations: "disabled", caret: "hide" })).toString("base64")}`;

    const scan = async (page: Page, cdp: CDPSession, stage: Stage): Promise<Scanned> => {
      const name = stageName(stage);
      const query = new URLSearchParams({
        entry: stage.entry,
        variant: stage.variant,
        entryPath: stage.source,
        frame: "component",
        reducedMotion: "true",
        ...stage.scheme.query,
      });
      try {
        await page.setViewportSize({ width: 760, height: Math.min(1100, Math.max(320, stage.height)) });
        await page.goto(`${stageServer!.origin}${stageServer!.framePath}?${query}`);
        await page.waitForFunction(() => document.documentElement.dataset.galleryReady, undefined, { timeout: 20_000 });
        if ((await page.evaluate(() => document.documentElement.dataset.galleryReady)) !== "1")
          return { stage: name, error: "the stage did not render" };
        await page.addStyleTag({
          content: "*, *::before, *::after { transition: none !important; animation: none !important; }",
        });
        await page.mouse.move(-10, -10);
        const controls = await page.evaluate(markControls);
        const failures: Failure[] = [];
        if (controls.length === 0) return { stage: name, controls: 0, failures };
        await cdp.send("DOM.enable");
        await cdp.send("CSS.enable");
        for (const state of stage.scheme.states) {
          await force(cdp, state);
          await settle(page);
          const drawn = await capture(page);
          const ink = await page.evaluate(hideInk, true);
          await settle(page);
          const bare = await capture(page);
          await page.evaluate(hideInk, false);
          const readings = await page.evaluate(readControls, { drawn, bare, scale: 2, controls, ink });
          for (const reading of readings) {
            const control = controls[reading.id]!;
            const minimum = minimumOf(control, reading);
            if (reading.ratio + 0.005 >= minimum) continue;
            failures.push({
              key: failureKey(name, state, reading.kind, control.label),
              stage: name,
              state,
              control,
              reading,
              minimum,
            });
          }
        }
        await force(cdp, "rest");
        return { stage: name, controls: controls.length, failures };
      } catch (error) {
        return { stage: name, error: String(error).split("\n")[0]! };
      }
    };

    // A stage that never settles holds its worker; past its deadline it is not read and its worker
    // goes on with a new page (as accent-glass-invariants does).
    const stageDeadlineMs = 60_000;
    const scanWithin = async (page: Page, cdp: CDPSession, stage: Stage): Promise<Scanned> => {
      let timer: ReturnType<typeof setTimeout> | undefined;
      const late = new Promise<Scanned>((resolve) => {
        // fixed-wait: a deadline, not a wait; a stage that answers clears it and goes on at once.
        timer = setTimeout(
          () => resolve({ stage: stageName(stage), error: `no answer in ${stageDeadlineMs / 1000} s` }),
          stageDeadlineMs,
        );
      });
      try {
        return await Promise.race([scan(page, cdp, stage), late]);
      } finally {
        clearTimeout(timer);
      }
    };

    test(`every control's ink reads in every theme and mode (part ${part} of ${parts})`, async () => {
      const results: Scanned[] = [];
      const queue = [...stages];
      await Promise.all(
        Array.from({ length: 6 }, async () => {
          let page: Page | undefined;
          let cdp: CDPSession | undefined;
          for (let stage = queue.shift(); stage; stage = queue.shift()) {
            if (!page || !cdp)
              try {
                page = await shared!.page();
                cdp = await page.context().newCDPSession(page);
              } catch (error) {
                results.push({ stage: stageName(stage), error: String(error).split("\n")[0]! });
                page = undefined;
                continue;
              }
            // fixed-wait: the stage's deadline above; each stage ends as soon as it is read.
            const result = await scanWithin(page, cdp, stage);
            results.push(result);
            if ("error" in result) {
              void shared!.closePage(page);
              page = undefined;
              cdp = undefined;
            }
            if (results.length % 50 === 0)
              console.log(
                `control-contrast: ${results.length}/${stages.length} stages, ${Math.round(performance.now() / 1000)}s`,
              );
          }
          if (page) await shared!.closePage(page);
        }),
      );
      expect(shared!.failure, "the shared Chromium").toBeUndefined();

      // A new failure holds only when a second read of its stage, on a fresh page, finds it again: one
      // capture taken mid-paint (a palette's rows drawn white on white, a hover fill caught half in)
      // must not fail a part. The second read's failures replace the first's for that stage.
      const isFresh = (failure: Failure) =>
        failure.reading.ratio < (baseline.get(classKey(failure.control.label, failure.reading.kind)) ?? Infinity);
      const recheck = stages.filter((stage) =>
        results.some(
          (result) => result.stage === stageName(stage) && "failures" in result && result.failures.some(isFresh),
        ),
      );
      if (recheck.length) {
        const page = await shared!.page();
        const cdp = await page.context().newCDPSession(page);
        for (const stage of recheck) {
          // fixed-wait: the stage's deadline above; each stage ends as soon as it is read.
          const again = await scanWithin(page, cdp, stage);
          if ("error" in again) continue;
          const seen = new Set(again.failures.map((failure) => failure.key));
          const index = results.findIndex((result) => result.stage === again.stage);
          const first = results[index]!;
          if ("failures" in first)
            results[index] = { ...first, failures: first.failures.filter((f) => !isFresh(f) || seen.has(f.key)) };
        }
        await shared!.closePage(page);
        console.log(`control-contrast: read ${recheck.length} stage(s) again to confirm their new failures`);
      }

      const fresh: string[] = [];
      const reported = new Set<string>();
      const worst = new Map<string, number>();
      const all: Failure[] = [];
      let controls = 0;
      for (const result of results.sort((a, b) => a.stage.localeCompare(b.stage))) {
        if ("error" in result) {
          console.warn(`control-contrast: not read ${result.stage}: ${result.error}`);
          continue;
        }
        controls += result.controls;
        for (const failure of result.failures) {
          if (reported.has(failure.key)) continue;
          reported.add(failure.key);
          all.push(failure);
          const r = failure.reading;
          const known = classKey(failure.control.label, r.kind);
          worst.set(known, Math.min(worst.get(known) ?? Infinity, r.ratio));
          if (r.ratio >= (baseline.get(known) ?? Infinity)) continue;
          fresh.push(`${failure.key}  (${r.ratio}:1 < ${failure.minimum}:1, ink ${r.ink} on ${r.ground})`);
        }
      }
      const out = process.env.CONTRAST_AUDIT_OUT || process.env.FAST_CHECKS_OUT;
      if (out) {
        writeReport(path.join(out, `control-contrast-${part}.md`), all, part, parts, results, controls);
        fs.writeFileSync(
          path.join(out, `control-contrast-${part}.baseline.txt`),
          [...worst]
            .map(([key, floor]) => `${key} ${floor}`)
            .sort()
            .join("\n") + "\n",
        );
      }
      // CONTROL_CONTRAST_PRINT_BASELINE=1 prints the worst reading per class, for a run whose
      // files stay on a fleet worker; the lines after the prefix are baseline lines.
      if (process.env.CONTROL_CONTRAST_PRINT_BASELINE === "1")
        for (const [key, floor] of [...worst].sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0)))
          console.log(`control-contrast baseline: ${key} ${floor}`);
      const read = results.filter((result) => !("error" in result));
      console.log(
        `control-contrast: read ${read.length} of ${stages.length} stages, ${controls} controls, ${all.length} failing readings, ${fresh.length} new`,
      );
      if (fresh.length) console.log(`control-contrast failures:\n${fresh.join("\n")}`);
      expect(fresh, `new control contrast failures across ${stages.length} gallery stages`).toEqual([]);
      // A run that read nothing proves nothing.
      expect(read.length, `stages read of ${stages.length}`).toBeGreaterThan(stages.length * 0.9);
      expect(controls).toBeGreaterThan(0);
    });
  });
}

/** The failing readings of one part as a Markdown table, worst first. */
function writeReport(
  file: string,
  failures: Failure[],
  part: number,
  parts: number,
  results: { stage: string }[],
  controls: number,
): void {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const rows = [...failures]
    .sort((a, b) => a.reading.ratio / a.minimum - b.reading.ratio / b.minimum)
    .map((f) =>
      [
        f.stage.replace(/@.*/, ""),
        f.stage.replace(/.*@/, ""),
        f.state,
        f.control.role + (f.control.disabled ? " (disabled)" : ""),
        f.reading.kind,
        `\`${f.control.label.replace(/\|/g, "\\|")}\``,
        `${f.reading.ratio.toFixed(2)}:1`,
        `${f.minimum}:1`,
        `${f.reading.ink} on ${f.reading.ground}`,
      ].join(" | "),
    );
  fs.writeFileSync(
    file,
    [
      `# Control contrast, part ${part} of ${parts}`,
      "",
      `${results.length} stages, ${controls} controls, ${failures.length} failing readings.`,
      "",
      "| entry | scheme | state | control | ink | label | measured | minimum | ink on ground |",
      "| --- | --- | --- | --- | --- | --- | --- | --- | --- |",
      ...rows.map((row) => `| ${row} |`),
      "",
    ].join("\n"),
  );
}
