// cmux-web-test-timeout: 600
// The composer's controls stand on its bottom line, whatever makes it taller. Leo, 2026-11-18, of an
// attachment card in his chat's prompt with +, Send and the mic centred in the taller box: "and the
// buttons should be at the bottom of the composer". leo-workspace design/composer.md (Controls).
//
// In every state (an empty prompt, a wrapped draft, a capped draft, an attachment in the prompt or
// over it, a running turn's Stop, a queued send) and on every composer with this layout (the chat
// and New Tab), +, Send or Stop and the mic stand the same distance over the box's bottom as on an
// empty one-line prompt: adding or removing an attachment, or a line, moves the box's top, never
// the controls. Chromium on the gallery stage; a 2x still of each state and its numbers go to
// webviews/artifacts/composer-controls-bottom/ (and FAST_CHECKS_OUT, which the fleet step uploads).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { copyFileSync, mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { PLUS_PICKER } from "../src/agent-session/acpmux/composerSelectors";

await requireBrowserLane("composer-controls-bottom.browser.test.ts", async () => {
  setDefaultTimeout(300_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("composer-controls-bottom: skipping (run `bunx playwright install chromium`)");
    describe.skip("composer controls on the bottom line", () => test("chromium", () => {}));
    return;
  }
  /** Subpixel rounding. */
  const TOLERANCE = 0.5;
  /** A wrapped draft: three lines or more at the stage's width. */
  const LONG =
    "Please look at why the hover preview bounces when the pointer rests on an attachment card, then check " +
    "the queue's rows and the tray over the composer for the same thing, and write down what you find";

  type State = {
    name: string;
    entry: string;
    variant: string;
    /** Text typed into the prompt before measuring. */
    type?: string;
    /** The box must be taller than its one-line height (the state grows it). */
    taller?: boolean;
    /** The controls the state must draw. */
    controls: ("plus" | "send" | "stop" | "mic")[];
  };
  /** One surface: its states, the first of which is its one-line reference. */
  const SURFACES: { name: string; states: State[] }[] = [
    {
      name: "chat",
      states: [
        { name: "empty", entry: "agent-pane.composer", variant: "idle", controls: ["plus", "mic"] },
        {
          name: "one-line",
          entry: "agent-pane.composer",
          variant: "idle",
          type: "helo",
          controls: ["plus", "send", "mic"],
        },
        {
          name: "multi-line",
          entry: "agent-pane.composer",
          variant: "idle",
          type: LONG,
          taller: true,
          controls: ["plus", "send", "mic"],
        },
        {
          name: "capped-draft",
          entry: "agent-pane.composer",
          variant: "long-draft",
          taller: true,
          controls: ["plus", "send", "mic"],
        },
        {
          name: "attachment-in-prompt",
          entry: "agent-pane.composer",
          variant: "attachment-inline-video",
          taller: true,
          controls: ["plus", "send", "mic"],
        },
        {
          name: "attachments-mixed",
          entry: "agent-pane.composer",
          variant: "attachments-inline-mixed",
          taller: true,
          controls: ["plus", "send", "mic"],
        },
        {
          name: "image-attached",
          entry: "agent-pane.composer",
          variant: "image-attached",
          taller: true,
          controls: ["plus", "send", "mic"],
        },
        // Mid-turn with an empty prompt the send slot is Stop (.acpmux-send.acpmux-cancel).
        {
          name: "streaming-stop",
          entry: "agent-pane.composer",
          variant: "working-stopping",
          controls: ["plus", "stop", "mic"],
        },
        { name: "queued", entry: "agent-pane.composer", variant: "queued", controls: ["plus"] },
      ],
    },
    {
      name: "new-tab",
      states: [
        { name: "empty", entry: "agent-pane.new-tab", variant: "minimal-default", controls: ["plus", "mic"] },
        {
          name: "multi-line",
          entry: "agent-pane.new-tab",
          variant: "minimal-default",
          type: LONG,
          taller: true,
          controls: ["plus", "mic"],
        },
      ],
    },
  ];
  const WIDTH = 560;

  const webviews = path.resolve(import.meta.dir, "..");
  const outDir = path.join(webviews, "artifacts", "composer-controls-bottom");
  mkdirSync(outDir, { recursive: true });
  const { createServer } = await import("vite");
  let vite: Awaited<ReturnType<typeof createServer>> | undefined;
  let browser: Browser | undefined;

  beforeAll(async () => {
    vite = await createServer({
      configFile: path.join(webviews, "vite.config.gallery-dev.ts"),
      server: { port: 0, host: "127.0.0.1", strictPort: false },
      logLevel: "error",
    });
    await vite.listen();
    browser = await chromium.launch({ headless: true });
    for (const surface of SURFACES)
      await warmGalleryFrame(vite, surface.states[0]!.entry, {
        browser,
        params: { variant: surface.states[0]!.variant },
      });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const open = async (state: State, scheme: "light" | "dark"): Promise<Page> => {
    const page = await browser!.newPage({ viewport: { width: WIDTH, height: 640 }, deviceScaleFactor: 2 });
    await page.addInitScript(() => {
      try {
        localStorage.setItem("cmux.composer.look", "claude");
      } catch {
        // No storage: the default look.
      }
    });
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const theme = scheme === "light" ? "Apple System Colors Light" : "Apple System Colors";
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(state.entry, { variant: state.variant, theme })}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    await page.locator(".nt-box, .acpmux-composer-box").first().waitFor();
    if (state.type) {
      await page.locator(".nt-field, .acpmux-composer-box .ProseMirror").first().click();
      await page.keyboard.type(state.type);
    }
    await page.evaluate(() => document.fonts.ready);
    await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
    return page;
  };

  type Box = { left: number; top: number; right: number; bottom: number };
  type Measured = {
    box: Box | null;
    controls: Partial<Record<"plus" | "send" | "stop" | "mic", Box>>;
    clip: { x: number; y: number; width: number; height: number } | null;
  };
  const measure = (page: Page) =>
    page.evaluate(
      ({ PLUS_PICKER }): Measured => {
        const plain = (rect: DOMRect): Box => ({
          left: rect.left,
          top: rect.top,
          right: rect.right,
          bottom: rect.bottom,
        });
        const card = document.querySelector(".nt-box") ?? document.querySelector(".acpmux-composer-box");
        const rect = card?.getBoundingClientRect();
        const box = rect && rect.width > 0 ? plain(rect) : null;
        const controls: Measured["controls"] = {};
        for (const [name, selector] of [
          ["plus", PLUS_PICKER],
          ["send", ".acpmux-send:not(.acpmux-cancel)"],
          ["stop", ".acpmux-cancel"],
          ["mic", ".acpmux-mic"],
        ] as const) {
          const button = [...(card?.querySelectorAll(selector) ?? [])].find((element) => {
            const r = element.getBoundingClientRect();
            return r.width > 0 && r.height > 0;
          });
          if (button) controls[name] = plain(button.getBoundingClientRect());
        }
        // The box and the rows around it: the queue or tray over it, the quiet row under it.
        const stack = card?.closest(".acpmux-composer, .nt-composer") ?? card;
        const around = stack?.getBoundingClientRect();
        const clip = around
          ? {
              x: Math.max(0, around.left - 8),
              y: Math.max(0, around.top - 8),
              width: Math.min(window.innerWidth, around.width + 16),
              height: around.height + 16,
            }
          : null;
        return { box, controls, clip };
      },
      { PLUS_PICKER },
    );

  const f = (value: number) => value.toFixed(2);
  const measured = new Map<string, Promise<Measured>>();
  const measureState = (surface: string, state: State): Promise<Measured> => {
    const key = `${surface}-${state.name}`;
    const known = measured.get(key);
    if (known) return known;
    const run = (async () => {
      let light: Measured | undefined;
      for (const scheme of ["light", "dark"] as const) {
        const page = await open(state, scheme);
        const m = await measure(page);
        const stem = `${key}-${scheme}`;
        writeFileSync(path.join(outDir, `${stem}.json`), `${JSON.stringify(m, null, 2)}\n`);
        if (m.clip) await page.screenshot({ path: path.join(outDir, `${stem}.png`), clip: m.clip });
        if (process.env.FAST_CHECKS_OUT) {
          const out = path.join(process.env.FAST_CHECKS_OUT, "composer-controls-bottom");
          mkdirSync(out, { recursive: true });
          for (const ext of ["json", "png"]) {
            try {
              copyFileSync(path.join(outDir, `${stem}.${ext}`), path.join(out, `${stem}.${ext}`));
            } catch {
              // No still (the box was not drawn): the test below says so.
            }
          }
        }
        console.log(
          `composer-controls-bottom ${JSON.stringify({
            state: key,
            scheme,
            boxHeight: m.box ? +(m.box.bottom - m.box.top).toFixed(2) : null,
            overBottom: Object.fromEntries(
              Object.entries(m.controls).map(([name, b]) => [
                name,
                m.box ? +(m.box.bottom - b.bottom).toFixed(2) : null,
              ]),
            ),
          })}`,
        );
        if (scheme === "light") light = m;
        await page.close();
      }
      return light!;
    })();
    measured.set(key, run);
    return run;
  };

  for (const surface of SURFACES) {
    const reference = surface.states[0]!;
    for (const state of surface.states) {
      test(`${surface.name} ${state.name}: +, Send and the mic stand on the bottom line`, async () => {
        const ref = await measureState(surface.name, reference);
        const m = await measureState(surface.name, state);
        const problems: string[] = [];
        if (!m.box || !ref.box) problems.push("the composer's box is not drawn");
        else {
          const oneLine = ref.box.bottom - ref.box.top;
          const height = m.box.bottom - m.box.top;
          if (state.taller && height <= oneLine + TOLERANCE)
            problems.push(`the box is ${f(height)} px tall, not taller than one line (${f(oneLine)})`);
          // The one-line reference's controls, over its bottom.
          const refPlus = ref.controls.plus;
          const expected = refPlus ? ref.box.bottom - refPlus.bottom : null;
          for (const name of state.controls) {
            const control = m.controls[name];
            if (!control) {
              problems.push(`${name} is not drawn`);
              continue;
            }
            const over = m.box.bottom - control.bottom;
            if (expected !== null && Math.abs(over - expected) > TOLERANCE)
              problems.push(`${name} stands ${f(over)} px over the box's bottom, not ${f(expected)} as on one line`);
          }
          // One bottom line across the row.
          const bottoms = Object.entries(m.controls);
          for (const [name, control] of bottoms) {
            const first = bottoms[0]![1];
            if (Math.abs(control.bottom - first.bottom) > TOLERANCE)
              problems.push(`${name}'s bottom is ${f(control.bottom - first.bottom)} px off ${bottoms[0]![0]}'s`);
          }
        }
        expect(problems).toEqual([]);
      });
    }
  }
});
