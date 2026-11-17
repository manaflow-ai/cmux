// A turn that another agent's message started must hold still while it runs and when it ends
// (Leo, 2026-11-17: "the jostles and shifts and spacing are still bad here"). Across the states of
// agent-pane.turn-header-steady the header line ("Working for …", then "Worked for …") is there from
// the first state and keeps its top and height, the prompt and the folded message run keep theirs,
// the sender chip sits on the preview's baseline, and the timer keeps its width as its digits change.
import { afterAll, beforeAll, expect, setDefaultTimeout, test } from "bun:test";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { requireBrowserLane } from "./support/requireBrowserLane";
import { devHighlightWorker } from "./support/devHighlightWorker";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { installPaintedFrames } from "./support/paintedFrames";

await requireBrowserLane("turn-header-steady-browser.test.ts", async () => {
  setDefaultTimeout(180_000);
  const ENTRY = "agent-pane.turn-header-steady";
  const STATES = ["started", "first-step", "ticking", "minutes", "counts-grow", "ended"] as const;
  type State = (typeof STATES)[number];
  const RUNNING: State[] = STATES.filter((state) => state !== "ended");
  const WIDTHS = [640, 420] as const;
  const HEIGHT = 420;
  const ROW_IDS = ["steady-prompt", "worked-steady-prompt", "messageRun-steady-send", "thinking-live"];
  // One row from the turn's start to its end: the running "Working for" and the ended "Worked for"
  // are the same row (one id, kind and element) in two phases.
  const headerId = (_state: State) => "worked-steady-prompt";

  type Box = { top: number; height: number };
  type Measured = {
    /** Every row in the scroller, top relative to the scroller's top. */
    rows: ({ id: string } & Box)[];
    /** The header row's inner `.cv-worked`. */
    worked: Box | null;
    /** The prompt row's chip and preview line. */
    baseline: { label: number; preview: number; chipMid: number; lineMid: number } | null;
    /** `.cv-worked__label-time` widths: as rendered, then with each substituted text. */
    timer: { text: string; width: number }[] | null;
    /** The header row's kind class and its chevron's slot (there, hidden or not, in every state). */
    headerKind: string | null;
    chevron: { left: number; width: number } | null;
    /** The prompt's sender mark: one fixed box, whatever picture comes. */
    mark: { width: number; height: number } | null;
  };

  let server: Awaited<ReturnType<typeof import("vite").createServer>>;
  let browser: Browser;
  let base: string;
  beforeAll(async () => {
    const { createServer } = await import("vite");
    const root = path.resolve(import.meta.dir, "..");
    server = await createServer({
      root,
      configFile: path.join(root, "vite.config.ts"),
      server: { port: 0, host: "127.0.0.1" },
      plugins: [devHighlightWorker()],
      logLevel: "error",
    });
    await server.listen();
    base = `http://127.0.0.1:${(server.httpServer!.address() as { port: number }).port}`;
    browser = await chromium.launch({ headless: true });
    await warmGalleryFrame(server, ENTRY, { browser, params: { variant: "started" } });
  });
  afterAll(async () => {
    await browser?.close();
    await server?.close();
  });

  const frame = (variant: State, width: number) =>
    `${base}${galleryFrame(ENTRY, {
      variant,
      theme: "Apple System Colors",
      colorScheme: "dark",
      width,
      height: HEIGHT,
    })}`;

  /** Texts the timer is re-rendered with, per state (check 5). */
  const TIMER_TEXTS: Partial<Record<State, string[]>> = { ticking: ["9s", "59s"], minutes: ["1m 7s", "9m 59s"] };

  async function measure(page: Page, state: State, width: number): Promise<Measured> {
    await page.goto(frame(state, width));
    await page.locator('[data-row-id="steady-prompt"], [data-row-id="worked-steady-prompt"]').first().waitFor();
    await page.evaluate(async () => {
      await document.fonts.ready;
      await window.cmuxPaintFrame();
      await window.cmuxPaintFrame();
      await window.cmuxPaintFrame();
    });
    const read = await page.evaluate(
      ({ header }) => {
        const scroller = document.querySelector<HTMLElement>(".acpmux-scroll");
        const origin = scroller ? scroller.getBoundingClientRect().top : 0;
        const box = (el: Element | null) => {
          if (!el) return null;
          const r = el.getBoundingClientRect();
          return { top: r.top - origin, height: r.height };
        };
        const rows = [...document.querySelectorAll<HTMLElement>("[data-row-id]")].map((el) => ({
          id: el.dataset.rowId!,
          ...box(el)!,
        }));
        const worked = box(document.querySelector(`[data-row-id="${header}"] .cv-worked`));
        const firstText = (el: Element | null) => {
          if (!el) return null;
          const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT, {
            acceptNode: (n) => (n.textContent?.trim() ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_SKIP),
          });
          const node = walker.nextNode();
          if (!node) return null;
          const range = document.createRange();
          range.selectNodeContents(node);
          return range.getBoundingClientRect();
        };
        const prompt = document.querySelector('[data-row-id="steady-prompt"]');
        const label = firstText(prompt?.querySelector(".cv-agent-tag__label") ?? null);
        const preview = firstText(prompt?.querySelector(".cv-agentmsg__preview") ?? null);
        const chip = prompt?.querySelector(".cv-agent-tag")?.getBoundingClientRect();
        const line = prompt?.querySelector(".cv-agentmsg__line")?.getBoundingClientRect();
        const baseline =
          label && preview && chip && line
            ? {
                label: label.bottom,
                preview: preview.bottom,
                chipMid: chip.top + chip.height / 2,
                lineMid: line.top + line.height / 2,
              }
            : null;
        const headerRow = document.querySelector<HTMLElement>(`[data-row-id="${header}"]`);
        const headerKind = headerRow
          ? ([...headerRow.classList].find((name) => /^acpmux-(worked|working)$/.test(name)) ?? null)
          : null;
        const chevronBox = headerRow?.querySelector(".cv-worked__chevron")?.getBoundingClientRect();
        const chevron = chevronBox ? { left: chevronBox.left, width: chevronBox.width } : null;
        const markBox = prompt?.querySelector(".cv-received__mark")?.getBoundingClientRect();
        const mark = markBox ? { width: markBox.width, height: markBox.height } : null;
        return { rows, worked, baseline, headerKind, chevron, mark };
      },
      { header: headerId(state) },
    );
    let timer: Measured["timer"] = null;
    const texts = TIMER_TEXTS[state];
    if (texts) {
      timer = [];
      const span = page.locator(`[data-row-id="${headerId(state)}"] .cv-worked__label-time`).first();
      if ((await span.count()) > 0) {
        const widthNow = (text: string | null) =>
          page.evaluate(
            async ({ header, text }) => {
              const el = document.querySelector<HTMLElement>(`[data-row-id="${header}"] .cv-worked__label-time`)!;
              if (text !== null) el.textContent = text;
              await window.cmuxPaintFrame();
              return { text: el.textContent ?? "", width: el.getBoundingClientRect().width };
            },
            { header: headerId(state), text },
          );
        timer.push(await widthNow(null));
        for (const text of texts) timer.push(await widthNow(text));
      }
    }
    return { ...read, timer };
  }

  const measured = new Map<number, Promise<Map<State, Measured>>>();
  const measureWidth = (width: number) => {
    let pending = measured.get(width);
    if (!pending) {
      pending = (async () => {
        const page = await browser.newPage({ viewport: { width, height: HEIGHT }, colorScheme: "dark" });
        try {
          await installPaintedFrames(page);
          const out = new Map<State, Measured>();
          for (const state of STATES) out.set(state, await measure(page, state, width));
          return out;
        } finally {
          await page.close();
        }
      })();
      measured.set(width, pending);
    }
    return pending;
  };

  const fmt = (n: number | undefined) => (n === undefined ? "-" : n.toFixed(1));
  /** Every row's top and height in every state, one line per row id, so a failure shows the shift. */
  function table(all: Map<State, Measured>, width: number): string {
    const ids = [...new Set([...ROW_IDS, ...[...all.values()].flatMap((m) => m.rows.map((r) => r.id))])];
    const lines = [`width ${width}: top+height per state (relative to .acpmux-scroll top)`];
    lines.push(["row".padEnd(30), ...STATES.map((s) => s.padStart(14))].join(""));
    for (const id of ids) {
      const cells = STATES.map((state) => {
        const row = all.get(state)!.rows.find((r) => r.id === id);
        return (row ? `${fmt(row.top)}+${fmt(row.height)}` : "-").padStart(14);
      });
      lines.push([id.padEnd(30), ...cells].join(""));
    }
    const workedCells = STATES.map((state) => {
      const w = all.get(state)!.worked;
      return (w ? `${fmt(w.top)}+${fmt(w.height)}` : "-").padStart(14);
    });
    lines.push(["(header .cv-worked)".padEnd(30), ...workedCells].join(""));
    return lines.join("\n");
  }

  /** Asserts the collected failures are none, printing the row table first when there are some. */
  function settle(all: Map<State, Measured>, width: number, failures: string[]) {
    if (failures.length || process.env.TURN_HEADER_TABLE === "1")
      console.log(`${table(all, width)}\n${failures.join("\n")}`);
    expect(failures).toEqual([]);
  }

  const same = (failures: string[], what: string, boxes: [State, Box | null | undefined][], tolerance = 0.5) => {
    const present = boxes.filter((entry): entry is [State, Box] => !!entry[1]);
    for (const [state, b] of boxes) if (!b) failures.push(`${what}: missing in ${state}`);
    if (!present.length) return;
    const [firstState, first] = present[0];
    for (const [state, b] of present.slice(1)) {
      if (Math.abs(b.top - first.top) > tolerance)
        failures.push(`${what}: top ${fmt(b.top)} in ${state} vs ${fmt(first.top)} in ${firstState}`);
      if (Math.abs(b.height - first.height) > tolerance)
        failures.push(`${what}: height ${fmt(b.height)} in ${state} vs ${fmt(first.height)} in ${firstState}`);
    }
  };
  const rowIn = (m: Measured, id: string) => m.rows.find((r) => r.id === id);

  for (const width of WIDTHS) {
    test(`${width}px: the header line is there in every state and holds its top and height`, async () => {
      const all = await measureWidth(width);
      const failures: string[] = [];
      same(
        failures,
        "header row",
        STATES.map((state) => [state, rowIn(all.get(state)!, headerId(state))]),
      );
      same(
        failures,
        "header .cv-worked",
        STATES.map((state) => [state, all.get(state)!.worked]),
      );
      // One kind in every state, and the chevron's slot held from the start, in one place.
      for (const state of STATES) {
        const m = all.get(state)!;
        if (m.headerKind !== "acpmux-worked") failures.push(`header kind in ${state}: ${m.headerKind}`);
        if (!m.chevron) failures.push(`header chevron slot: missing in ${state}`);
      }
      const chevrons = STATES.flatMap((state) => {
        const c = all.get(state)!.chevron;
        return c ? [[state, c] as const] : [];
      });
      for (const [state, c] of chevrons.slice(1))
        if (Math.abs(c.left - chevrons[0]![1].left) > 0.5 || Math.abs(c.width - chevrons[0]![1].width) > 0.5)
          failures.push(
            `header chevron: left ${fmt(c.left)} in ${state} vs ${fmt(chevrons[0]![1].left)} in ${chevrons[0]![0]}`,
          );
      settle(all, width, failures);
    });

    test(`${width}px: the prompt holds still under the header while the turn runs`, async () => {
      const all = await measureWidth(width);
      const failures: string[] = [];
      same(
        failures,
        "prompt row",
        RUNNING.map((state) => [state, rowIn(all.get(state)!, "steady-prompt")]),
      );
      for (const state of RUNNING) {
        const prompt = rowIn(all.get(state)!, "steady-prompt");
        const header = rowIn(all.get(state)!, headerId(state));
        if (prompt && header && prompt.top < header.top + header.height - 0.5)
          failures.push(
            `prompt row: top ${fmt(prompt.top)} above the header's bottom ${fmt(header.top + header.height)} in ${state}`,
          );
      }
      settle(all, width, failures);
    });

    test(`${width}px: the folded message run holds still as the turn grows`, async () => {
      const all = await measureWidth(width);
      const failures: string[] = [];
      same(
        failures,
        "messageRun-steady-send",
        (["ticking", "minutes", "counts-grow"] as State[]).map((state) => [
          state,
          rowIn(all.get(state)!, "messageRun-steady-send"),
        ]),
      );
      settle(all, width, failures);
    });

    test(`${width}px: the sender chip and the preview share a baseline, the chip centred on the line`, async () => {
      const all = await measureWidth(width);
      const failures: string[] = [];
      for (const state of RUNNING) {
        const b = all.get(state)!.baseline;
        if (!b) {
          failures.push(`prompt line: chip label, preview, chip or line missing in ${state}`);
          continue;
        }
        if (Math.abs(b.label - b.preview) > 0.5)
          failures.push(`baseline in ${state}: chip label bottom ${fmt(b.label)} vs preview bottom ${fmt(b.preview)}`);
        if (Math.abs(b.chipMid - b.lineMid) > 1)
          failures.push(`chip centre in ${state}: ${fmt(b.chipMid)} vs line centre ${fmt(b.lineMid)}`);
      }
      // The sender's mark is one fixed box in every state, so a picture that comes later swaps in place.
      const marks = RUNNING.map((state) => [state, all.get(state)!.mark] as const);
      for (const [state, m] of marks)
        if (!m || Math.abs(m.width - marks[0]![1]!.width) > 0.5 || Math.abs(m.height - marks[0]![1]!.height) > 0.5)
          failures.push(`sender mark in ${state}: ${m ? `${fmt(m.width)}x${fmt(m.height)}` : "missing"}`);
      settle(all, width, failures);
    });

    test(`${width}px: the timer reserves its width as its digits change`, async () => {
      const all = await measureWidth(width);
      const failures: string[] = [];
      for (const state of ["ticking", "minutes"] as State[]) {
        const timer = all.get(state)!.timer;
        if (!timer?.length) {
          failures.push(`timer: no .cv-worked__label-time in the ${state} header`);
          continue;
        }
        const [first, ...rest] = timer;
        for (const t of rest)
          if (Math.abs(t.width - first.width) > 0.5)
            failures.push(
              `timer in ${state}: "${t.text}" is ${fmt(t.width)}px wide vs "${first.text}" ${fmt(first.width)}px`,
            );
      }
      settle(all, width, failures);
    });
  }
});
