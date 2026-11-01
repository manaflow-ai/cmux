// cmux-web-test-timeout: 600
// The composer's leading and trailing controls, in every layout and both looks. Leo, 2026-10-31:
// "composer still looks like shit with the + spacing indent to the text" and "why is our shit not
// vertically centered like claude's is??? applies to the send and mic buttons". leo-workspace
// design/composer.md (Controls) and design/grid.md 5.1.
//
// 1. The + to text gap (Claude's look): the text (the placeholder, the caret, what is typed) starts
//    one `--acpmux-composer-lead-gap` (8 px) after the + button.
// 2. One left column: + starts on the box's control inset, and the rows that hang off the box stand
//    on it. A row of boxes (the attachment tiles in it) starts on the inset; a row of marks (the
//    project and machine strip over it, the quiet row under it, New Tab's suggestions) puts its
//    leading glyph's center on the + glyph's center, or its leading text on the + glyph's left edge.
// 3. Centered controls: +, the mic and Send are one size (`--acpmux-composer-control`), each glyph
//    sits at its button's center, and every button stands the same inset off the box's edges on
//    every side it meets (left, top and bottom for +; right, top and bottom for the last trailing
//    control). In Claude's look the three centers are the prompt's first line's center (a one-line
//    prompt); in Codex's, the controls' own row under the prompt.
// 4. Room around the text (Claude's look; Leo, 2026-11-01: "this is all still not aligned there's not
//    enough of a space at the bottom"): the caret's center is +'s center, the first line has as much
//    room under it as over it, and at least MIN_ROOM under its text, so it never sits on the edge.
//    + stands as far off the box's top as its bottom, and as far off its left as the last control
//    off its right.
//
// Chromium on the gallery stage: the chat pane (normal, narrow, a draft, an image), Home (a new
// chat's composer) and New Tab (its default page, a typed draft with its suggestions, narrow), in
// Claude's look and in Codex's. Every layout's numbers and a 2x still, light and dark, go to
// webviews/artifacts/composer-plus-geometry/ (and FAST_CHECKS_OUT, which the fleet step uploads).
import { afterAll, beforeAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { copyFileSync, existsSync, mkdirSync, writeFileSync } from "node:fs";
import path from "node:path";
import { chromium, type Browser, type Page } from "playwright";
import { galleryFrame, warmGalleryFrame } from "./support/galleryFrame";
import { requireBrowserLane } from "./support/requireBrowserLane";

await requireBrowserLane("composer-plus-geometry.test.ts", async () => {
  setDefaultTimeout(300_000);
  try {
    await (await chromium.launch({ headless: true })).close();
  } catch {
    console.warn("composer-plus-geometry: skipping (run `bunx playwright install chromium`)");
    describe.skip("composer + geometry", () => test("chromium", () => {}));
    return;
  }
  /** --acpmux-composer-lead-gap: from the + button's right edge to the text's start. */
  const GAP = 8;
  /** Subpixel rounding. */
  const TOLERANCE = 0.5;
  /** The least room under a one-line prompt's text, to the box's bottom (10 px block inset). */
  const MIN_ROOM = 12;

  type Row = "chips" | "pills" | "foot" | "suggestions";
  type Layout = {
    name: string;
    entry: string;
    variant: string;
    width: number;
    look: "claude" | "codex";
    /** Text typed into the prompt before measuring (a ProseMirror prompt or New Tab's textarea). */
    type?: string;
    /** Rows the layout must draw, each checked against the left column. */
    expect?: Row[];
    /** Trailing controls the layout must draw. */
    trailing?: ("mic" | "send")[];
  };
  const LAYOUTS: Layout[] = [
    {
      name: "chat",
      entry: "agent-pane.composer-row",
      variant: "claude-auto",
      width: 760,
      look: "claude",
      expect: ["foot"],
      trailing: ["mic"],
    },
    {
      name: "chat-typed",
      entry: "agent-pane.composer-row",
      variant: "claude-auto",
      width: 760,
      look: "claude",
      type: "helo",
      trailing: ["mic", "send"],
    },
    {
      name: "chat-image",
      entry: "agent-pane.composer",
      variant: "image-attached",
      width: 760,
      look: "claude",
    },
    {
      name: "chat-narrow",
      entry: "agent-pane.narrow",
      variant: "controls",
      width: 280,
      look: "claude",
      expect: ["foot"],
    },
    {
      name: "home",
      entry: "agent-pane.new-chat-composer",
      variant: "claude",
      width: 760,
      look: "claude",
      expect: ["pills"],
      trailing: ["mic"],
    },
    {
      name: "new-tab",
      entry: "agent-pane.new-tab",
      variant: "minimal-default",
      width: 760,
      look: "claude",
      expect: ["pills", "foot"],
      trailing: ["mic", "send"],
    },
    {
      name: "new-tab-suggestions",
      entry: "agent-pane.new-tab",
      variant: "suggestions-minimal-ff",
      width: 760,
      look: "claude",
      expect: ["suggestions"],
      trailing: ["mic", "send"],
    },
    {
      name: "new-tab-narrow",
      entry: "agent-pane.narrow",
      variant: "new-tab-default",
      width: 280,
      look: "claude",
      expect: ["foot"],
    },
    {
      name: "chat-codex",
      entry: "agent-pane.composer-row",
      variant: "claude-auto",
      width: 760,
      look: "codex",
      type: "helo",
      trailing: ["mic", "send"],
    },
    {
      name: "home-codex",
      entry: "agent-pane.new-chat-composer",
      variant: "claude",
      width: 760,
      look: "codex",
      trailing: ["mic"],
    },
    {
      name: "new-tab-codex",
      entry: "agent-pane.new-tab",
      variant: "minimal-default",
      width: 760,
      look: "codex",
      trailing: ["mic", "send"],
    },
  ];

  const webviews = path.resolve(import.meta.dir, "..");
  const outDir = path.join(webviews, "artifacts", "composer-plus-geometry");
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
    for (const entry of new Set(LAYOUTS.map((layout) => layout.entry)))
      await warmGalleryFrame(vite, entry, {
        browser,
        params: { variant: LAYOUTS.find((layout) => layout.entry === entry)!.variant },
      });
  });
  afterAll(async () => {
    await browser?.close();
    await vite?.close();
  });

  const open = async (layout: Layout, scheme: "light" | "dark"): Promise<Page> => {
    const page = await browser!.newPage({ viewport: { width: layout.width, height: 600 }, deviceScaleFactor: 2 });
    // The look is the viewer's (composerLook.ts, localStorage), read as the page starts.
    await page.addInitScript((look) => {
      try {
        localStorage.setItem("cmux.composer.look", look);
      } catch {
        // No storage: the default look.
      }
    }, layout.look);
    const port = (vite!.httpServer!.address() as { port: number }).port;
    const theme = scheme === "light" ? "Apple System Colors Light" : "Apple System Colors";
    await page.goto(`http://127.0.0.1:${port}${galleryFrame(layout.entry, { variant: layout.variant, theme })}`);
    await page.waitForFunction(() => document.documentElement.dataset.galleryReady === "1", undefined, {
      timeout: 120_000,
    });
    await page.locator(".nt-box, .acpmux-composer-box").first().waitFor();
    if (layout.type) {
      await page.locator(".nt-field, .acpmux-composer-box .ProseMirror").first().click();
      await page.keyboard.type(layout.type);
    }
    if (layout.expect?.includes("suggestions")) await page.locator(".nt-popover .nt-row").first().waitFor();
    await page.evaluate(() => document.fonts.ready);
    await page.evaluate(() => new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done))));
    return page;
  };

  type Box = { left: number; top: number; right: number; bottom: number };
  /** A control: its button, its glyph's ink (centering) and its glyph's box (the column). */
  type Control = { button: Box; glyph: Box | null; glyphBox: Box | null };
  type Measured = {
    look: string | null;
    box: Box | null;
    plus: Control | null;
    mic: Control | null;
    send: Control | null;
    /** Codex's controls row inside the box under the prompt, when + sits in one. */
    bar: Box | null;
    /** The prompt's first line, from the viewport: the center of its text's box (a range's box, the
        font's ascent to descent, which is what the eye centers: design/grid.md rule 7), not its line box. */
    line: { top: number; center: number; bottom: number; source: string } | null;
    /** The caret's box in a focused ProseMirror prompt (its collapsed selection), when one is drawn. */
    caret: Box | null;
    /** Where the placeholder's (or, with a draft, the typed text's) first character's box starts. */
    text: number | null;
    textSource: string;
    /** The prompt holds an attachment placed in its text (taller than one text line). */
    inline: boolean;
    /** The rows that hang off the box, from its left edge: a row of boxes by its first box's left
        edge, a row of marks by its leading mark (a glyph or a character). */
    rows: {
      chips: number | null;
      pills: { left: number; center: number; kind: string } | null;
      foot: { left: number; center: number; kind: string } | null;
      suggestions: { left: number; center: number; kind: string } | null;
    };
    clip: { x: number; y: number; width: number; height: number } | null;
    /** New Tab's suggestions popover: its fill's alpha and its backdrop filter. */
    popover: { alpha: number; backdrop: string } | null;
  };
  const measure = (page: Page) =>
    page.evaluate((): Measured => {
      const plain = (rect: DOMRect): Box => ({
        left: rect.left,
        top: rect.top,
        right: rect.right,
        bottom: rect.bottom,
      });
      const shown = (element: Element | null | undefined) => {
        if (!element) return null;
        const rect = element.getBoundingClientRect();
        return rect.width > 0 && rect.height > 0 ? rect : null;
      };
      const firstChar = (element: Element | null | undefined) => {
        if (!element) return null;
        const walker = document.createTreeWalker(element, NodeFilter.SHOW_TEXT);
        for (let node = walker.nextNode(); node; node = walker.nextNode()) {
          if (!node.textContent?.trim()) continue;
          const range = document.createRange();
          const start = node.textContent.search(/\S/);
          range.setStart(node, start);
          range.setEnd(node, start + 1);
          const rect = range.getBoundingClientRect();
          if (rect.width > 0) return rect;
        }
        return null;
      };
      /** A glyph's ink: the union of its drawn shapes' boxes (an svg's own box is its viewBox). */
      const ink = (svg: Element | null | undefined): Box | null => {
        if (!svg) return null;
        const shapes = [...svg.querySelectorAll("path, line, circle, rect, polyline, polygon, ellipse")]
          .map((shape) => shape.getBoundingClientRect())
          .filter((rect) => rect.width > 0 || rect.height > 0);
        const rects = shapes.length ? shapes : [svg.getBoundingClientRect()];
        return {
          left: Math.min(...rects.map((rect) => rect.left)),
          top: Math.min(...rects.map((rect) => rect.top)),
          right: Math.max(...rects.map((rect) => rect.right)),
          bottom: Math.max(...rects.map((rect) => rect.bottom)),
        };
      };
      const card = document.querySelector(".nt-box") ?? document.querySelector(".acpmux-composer-box");
      const box = shown(card);
      const control = (selector: string): Control | null => {
        const buttons = [...(card?.querySelectorAll(selector) ?? [])].filter((element) => shown(element));
        const button = buttons[0];
        if (!button) return null;
        const svg = button.querySelector("svg");
        return {
          button: plain(button.getBoundingClientRect()),
          glyph: ink(svg),
          glyphBox: svg ? plain(svg.getBoundingClientRect()) : null,
        };
      };
      // Codex's row: the chat's bar, or New Tab's pickers row in the box under the field (cmux #28901;
      // Claude's look puts New Tab's + in the field's row, .nt-input, instead).
      const barElement = card
        ?.querySelector(".acpmux-composer-plus")
        ?.closest(".acpmux-composer-bar:not(.acpmux-composer-inner), .nt-box > .acpmux-chrome-area > .nt-pickers");
      const bar = barElement ? shown(barElement) : null;
      const plus = control(".acpmux-composer-plus .acpmux-picker-button");
      const mic = control(".acpmux-mic");
      const send = control(".acpmux-send");
      let text: number | null = null;
      let textSource = "none";
      let line: Measured["line"] = null;
      let inline = false;
      const area = card?.querySelector<HTMLTextAreaElement>("textarea.nt-field");
      if (area) {
        // A textarea draws its placeholder and its value from its content box's left edge.
        const style = getComputedStyle(area);
        const rect = area.getBoundingClientRect();
        text = rect.left + parseFloat(style.borderLeftWidth) + parseFloat(style.paddingLeft);
        textSource = area.value ? "textarea value" : "textarea placeholder";
        const top = rect.top + parseFloat(style.borderTopWidth) + parseFloat(style.paddingTop) - area.scrollTop;
        // A textarea's text has no range: a probe line in its font, on its first line's box.
        const probe = document.createElement("div");
        probe.textContent = "helo";
        Object.assign(probe.style, {
          position: "fixed",
          left: "0px",
          top: `${top}px`,
          font: style.font,
          lineHeight: style.lineHeight,
          letterSpacing: style.letterSpacing,
          whiteSpace: "pre",
          margin: "0",
          padding: "0",
          visibility: "hidden",
        });
        document.body.append(probe);
        const glyphs = document.createRange();
        glyphs.selectNodeContents(probe);
        const ink = glyphs.getBoundingClientRect();
        probe.remove();
        line = { top: ink.top, center: (ink.top + ink.bottom) / 2, bottom: ink.bottom, source: "textarea" };
      } else {
        const prompt = card?.querySelector(".ProseMirror");
        const typed = firstChar(prompt);
        const placeholder = firstChar(card?.querySelector(".acpmux-md-placeholder"));
        const chosen = typed ?? placeholder;
        if (chosen) {
          text = chosen.left;
          textSource = typed ? "typed" : "placeholder";
        } else {
          // A prompt that holds only an attachment (placed inline at the caret, cmux #26545) starts its
          // line where the attachment's margin box starts.
          const atom = [...(prompt?.querySelectorAll(".acpmux-md-inline") ?? [])].find((element) => shown(element));
          if (atom) {
            text = atom.getBoundingClientRect().left - parseFloat(getComputedStyle(atom).marginLeft);
            textSource = "inline attachment";
          }
        }
        inline = !!prompt?.querySelector(".acpmux-md-inline");
        // The first line's text: what is typed, else the placeholder.
        if (chosen)
          line = {
            top: chosen.top,
            center: (chosen.top + chosen.bottom) / 2,
            bottom: chosen.bottom,
            source: textSource,
          };
      }
      /** The leftmost drawn mark in `root`: a glyph (svg, img) or a text character, and what it is. */
      const leadingMark = (root: Element | null) => {
        if (!root) return null;
        let best: { left: number; center: number; kind: string } | null = null;
        const take = (left: number, center: number, kind: string) => {
          if (!best || left < best.left) best = { left, center, kind };
        };
        for (const glyph of root.querySelectorAll("svg, img")) {
          const rect = shown(glyph);
          if (rect) take(rect.left, rect.left + rect.width / 2, "glyph");
        }
        const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
        for (let node = walker.nextNode(); node; node = walker.nextNode()) {
          const start = node.textContent?.search(/\S/) ?? -1;
          if (start < 0 || !node.parentElement || !shown(node.parentElement)) continue;
          if (getComputedStyle(node.parentElement).visibility === "hidden") continue;
          const range = document.createRange();
          range.setStart(node, start);
          range.setEnd(node, start + 1);
          const rect = range.getBoundingClientRect();
          if (rect.width > 0) take(rect.left, rect.left + rect.width / 2, "text");
        }
        return best as { left: number; center: number; kind: string } | null;
      };
      /** A row that holds boxes (attachment tiles): its leftmost box's left edge, from the box's. */
      const boxRow = (selector: string) => {
        const rects = [...document.querySelectorAll(selector)].map(shown).filter((rect): rect is DOMRect => !!rect);
        return rects.length && box ? Math.min(...rects.map((rect) => rect.left)) - box.left : null;
      };
      /** A row of marks: its leading mark, from the box's left. */
      const markRow = (selector: string) => {
        const root = [...document.querySelectorAll(selector)].find((element) => shown(element)) ?? null;
        const mark = leadingMark(root);
        // Only a mark in the box's left half leads the row (a row of trailing controls has none).
        if (!mark || !box || mark.left - box.left > box.width / 2) return null;
        return { left: mark.left - box.left, center: mark.center - box.left, kind: mark.kind };
      };
      // The caret: a collapsed selection's client rect inside the prompt (Chromium draws the caret there).
      let caret: Box | null = null;
      const selection = getSelection();
      const prompt = card?.querySelector(".ProseMirror");
      if (prompt && selection?.rangeCount && prompt.contains(selection.anchorNode)) {
        const rect = [...selection.getRangeAt(0).getClientRects()].find((r) => r.height > 0);
        if (rect) caret = plain(rect);
      }
      const rows = {
        chips: boxRow(
          ".acpmux-composer-box > .acpmux-attachments .acpmux-attachment, .nt-box > .acpmux-attachments .acpmux-attachment",
        ),
        pills: markRow(".nt-above, .acpmux-composer > .acpmux-composer-strip"),
        foot: markRow(".acpmux-composer-foot"),
        suggestions: markRow(".nt-popover .nt-row"),
      };
      const firstShown = (selector: string) => {
        for (const element of document.querySelectorAll(selector)) {
          const rect = shown(element);
          if (rect) return rect;
        }
        return null;
      };
      // The still: the box and every row that hangs off it, with room around them.
      const parts = [
        box,
        firstShown(".nt-above"),
        firstShown(".acpmux-composer > .acpmux-composer-strip"),
        firstShown(".acpmux-composer-foot"),
        firstShown(".nt-popover"),
      ].filter((rect): rect is DOMRect => rect !== null);
      const pad = 16;
      const clip = parts.length
        ? (() => {
            const x = Math.max(0, Math.min(...parts.map((rect) => rect.left)) - pad);
            const y = Math.max(0, Math.min(...parts.map((rect) => rect.top)) - pad);
            const right = Math.min(innerWidth, Math.max(...parts.map((rect) => rect.right)) + pad);
            const bottom = Math.min(innerHeight, Math.max(...parts.map((rect) => rect.bottom)) + pad);
            return { x, y, width: right - x, height: bottom - y };
          })()
        : null;
      const popoverElement = [...document.querySelectorAll(".nt-popover")].find((element) => shown(element));
      const popover = popoverElement
        ? (() => {
            const style = getComputedStyle(popoverElement);
            // rgba(r, g, b, a), rgb(r, g, b) or color(srgb r g b / a).
            const color = style.backgroundColor;
            const slash = color.match(/\/\s*([\d.]+)\s*\)$/);
            const rgba = color.match(/^rgba\([^,]+,[^,]+,[^,]+,\s*([\d.]+)\)$/);
            const alpha = slash ? Number(slash[1]) : rgba ? Number(rgba[1]) : 1;
            return { alpha, backdrop: style.backdropFilter || style.getPropertyValue("-webkit-backdrop-filter") };
          })()
        : null;
      return {
        popover,
        look:
          document.querySelector("[data-composer-look]")?.getAttribute("data-composer-look") ??
          (document.querySelector(".nt-box, .acpmux-composer-box") ? "claude" : null),
        box: box ? plain(box) : null,
        bar: bar ? plain(bar) : null,
        plus,
        mic,
        send,
        line,
        caret,
        text,
        textSource,
        inline,
        rows,
        clip,
      };
    });

  const f = (n: number) => n.toFixed(2);
  const centerY = (box: Box) => (box.top + box.bottom) / 2;
  const centerX = (box: Box) => (box.left + box.right) / 2;

  /** The + to text gap and the left column (1 and 2). */
  const columnProblems = (layout: Layout, m: Measured): string[] => {
    const out: string[] = [];
    if (!m.box) return ["the composer box is not drawn"];
    if (!m.plus) return ["the + button is not drawn in the box"];
    const plus = m.plus.button;
    const inset = plus.left - m.box.left;
    // In Codex's look + sits in the row under the prompt, not beside the text.
    if (!m.bar) {
      if (m.text === null) return ["the text's start is not drawn"];
      const gap = m.text - plus.right;
      if (Math.abs(gap - GAP) > TOLERANCE)
        out.push(`the text (${m.textSource}) starts ${f(gap)} px after +, not ${GAP}`);
    }
    // The column is the + glyph's 16 px box (its left edge and center), not its ink.
    const glyph = m.plus.glyphBox;
    const glyphLeft = glyph ? glyph.left - m.box.left : null;
    const glyphCenter = glyph ? centerX(glyph) - m.box.left : null;
    // The suggestions' popover frosts what is under it: the menus' tint (78%) and a blur.
    if (layout.expect?.includes("suggestions")) {
      if (!m.popover) out.push("the suggestions' popover is not drawn");
      else {
        if (m.popover.alpha < 0.85)
          out.push(`the suggestions' fill is ${f(m.popover.alpha)} opaque, under the + menu's 0.86`);
        if (!/blur\(/.test(m.popover.backdrop))
          out.push(`the suggestions' popover has no blur (${m.popover.backdrop})`);
      }
    }
    for (const row of layout.expect ?? []) {
      const at = m.rows[row];
      if (at === null || at === undefined) {
        out.push(`the ${row} row is not drawn`);
        continue;
      }
      if (typeof at === "number") {
        if (Math.abs(at - inset) > TOLERANCE)
          out.push(`the ${row} row starts ${f(at)} px into the box, + ${f(inset)} px`);
      } else if (glyphLeft !== null && glyphCenter !== null) {
        const off = at.kind === "glyph" ? at.center - glyphCenter : at.left - glyphLeft;
        if (Math.abs(off) > TOLERANCE)
          out.push(
            `the ${row} row's leading ${at.kind} sits ${f(at.kind === "glyph" ? at.center : at.left)} px into the box, the + glyph's column ${f(at.kind === "glyph" ? glyphCenter : glyphLeft)} px`,
          );
      }
    }
    return out;
  };

  /** One size, centered glyphs, equal insets and one center line (3). */
  const centerProblems = (layout: Layout, m: Measured): string[] => {
    const out: string[] = [];
    if (!m.box) return ["the composer box is not drawn"];
    const named = { plus: m.plus, mic: m.mic, send: m.send };
    if (!m.plus) out.push("the + button is not drawn in the box");
    for (const name of layout.trailing ?? []) if (!named[name]) out.push(`the ${name} button is not drawn in the box`);
    const shown = Object.entries(named).filter((entry): entry is [string, Control] => entry[1] !== null);
    if (!shown.length) return out;
    // One size.
    const size = (control: Control) => control.button.bottom - control.button.top;
    const first = shown[0]!;
    for (const [name, control] of shown) {
      if (Math.abs(size(control) - size(first[1])) > TOLERANCE)
        out.push(`${name} is ${f(size(control))} px tall, ${first[0]} ${f(size(first[1]))} px`);
      if (control.glyph) {
        const dx = centerX(control.glyph) - centerX(control.button);
        const dy = centerY(control.glyph) - centerY(control.button);
        if (Math.abs(dx) > TOLERANCE || Math.abs(dy) > TOLERANCE)
          out.push(`${name}'s glyph sits ${f(dx)}, ${f(dy)} px off its button's center`);
      }
    }
    // One center line: the prompt's first line in Claude's look, the controls' row in Codex's.
    const target =
      !m.bar && m.line ? { y: m.line.center, what: "the first line" } : { y: centerY(first[1].button), what: first[0] };
    for (const [name, control] of shown) {
      const dy = centerY(control.button) - target.y;
      if (Math.abs(dy) > TOLERANCE) out.push(`${name}'s center sits ${f(dy)} px off ${target.what}'s center`);
    }
    // Equal insets. In Codex's look + stands as far off the box's left as off its row's bottom (the
    // look's dots sit under it in the box), and the last control as far off its right. In Claude's,
    // + stands as far under the box's top as over its bottom (one line), and as far off its left as
    // the last control off its right.
    const floor = m.bar ? m.bar.bottom : m.box.bottom;
    const oneLine = !m.bar && !m.rows.chips && !m.inline;
    // The last control is the rightmost one shown (the mic stands after Send in some layouts).
    const last = [m.send, m.mic]
      .filter((control): control is Control => control !== null)
      .sort((a, b) => b.button.right - a.button.right)[0];
    if (m.plus) {
      const b = m.plus.button;
      const left = b.left - m.box.left;
      const bottom = floor - b.bottom;
      if (m.bar) {
        if (Math.abs(left - bottom) > TOLERANCE)
          out.push(`+ stands ${f(left)} px off the box's left, ${f(bottom)} off its bottom`);
      } else {
        const top = b.top - m.box.top;
        // Over the attachments' band or beside an inline attachment the prompt is taller than one
        // line, and + stays on its last line.
        if (Math.abs(top - bottom) > TOLERANCE && oneLine)
          out.push(`+ stands ${f(top)} px under the box's top, ${f(bottom)} over its bottom`);
        if (last) {
          const right = m.box.right - last.button.right;
          if (Math.abs(left - right) > TOLERANCE)
            out.push(`+ stands ${f(left)} px off the box's left, the last control ${f(right)} off its right`);
        }
      }
    }
    if (last) {
      const right = m.box.right - last.button.right;
      const bottom = floor - last.button.bottom;
      if (m.bar && Math.abs(right - bottom) > TOLERANCE)
        out.push(`the last control stands ${f(right)} px off the box's right, ${f(bottom)} off its bottom`);
      if (!m.bar && m.plus && Math.abs(bottom - (floor - m.plus.button.bottom)) > TOLERANCE)
        out.push(`the last control stands ${f(bottom)} px over the box's bottom, + ${f(floor - m.plus.button.bottom)}`);
    }
    // Room around the text (4), Claude's look on one line.
    if (oneLine && m.line) {
      const over = m.line.top - m.box.top;
      const under = m.box.bottom - m.line.bottom;
      if (Math.abs(over - under) > TOLERANCE)
        out.push(`the first line has ${f(over)} px over it and ${f(under)} px under it`);
      if (under < MIN_ROOM - TOLERANCE) out.push(`the first line has ${f(under)} px under it, under ${MIN_ROOM}`);
    }
    if (!m.bar && m.caret && m.plus) {
      const dy = centerY(m.caret) - centerY(m.plus.button);
      if (Math.abs(dy) > TOLERANCE) out.push(`the caret's center sits ${f(dy)} px off +'s center`);
    }
    return out;
  };

  const measured = new Map<string, Promise<Measured>>();
  /** The layout's light page's numbers, its stills (light and dark) written once. */
  const measureLayout = (layout: Layout) => {
    const known = measured.get(layout.name);
    if (known) return known;
    const run = (async () => {
      let light: Measured | undefined;
      for (const scheme of ["light", "dark"] as const) {
        const page = await open(layout, scheme);
        const m = await measure(page);
        const stem = `${layout.name}-${scheme}`;
        writeFileSync(path.join(outDir, `${stem}.json`), `${JSON.stringify(m, null, 2)}\n`);
        if (m.clip) await page.screenshot({ path: path.join(outDir, `${stem}.png`), clip: m.clip });
        if (process.env.FAST_CHECKS_OUT) {
          const out = path.join(process.env.FAST_CHECKS_OUT, "composer-plus-geometry");
          mkdirSync(out, { recursive: true });
          for (const ext of ["json", "png"]) {
            const file = path.join(outDir, `${stem}.${ext}`);
            if (existsSync(file)) copyFileSync(file, path.join(out, `${stem}.${ext}`));
          }
        }
        const rel = (control: Control | null) =>
          control && m.box
            ? {
                left: +(control.button.left - m.box.left).toFixed(2),
                top: +(control.button.top - m.box.top).toFixed(2),
                right: +(m.box.right - control.button.right).toFixed(2),
                bottom: +(m.box.bottom - control.button.bottom).toFixed(2),
                size: +(control.button.bottom - control.button.top).toFixed(2),
                glyphDy: control.glyph ? +(centerY(control.glyph) - centerY(control.button)).toFixed(2) : null,
              }
            : null;
        console.log(
          `composer-plus-geometry ${JSON.stringify({
            layout: layout.name,
            scheme,
            look: m.look,
            boxHeight: m.box ? +(m.box.bottom - m.box.top).toFixed(2) : null,
            gap: m.plus && m.text !== null ? +(m.text - m.plus.button.right).toFixed(2) : null,
            textFromBox: m.box && m.text !== null ? +(m.text - m.box.left).toFixed(2) : null,
            lineCenterFromTop: m.box && m.line ? +(m.line.center - m.box.top).toFixed(2) : null,
            lineRoom:
              m.box && m.line
                ? [+(m.line.top - m.box.top).toFixed(2), +(m.box.bottom - m.line.bottom).toFixed(2)]
                : null,
            caretCenterFromTop: m.box && m.caret ? +(centerY(m.caret) - m.box.top).toFixed(2) : null,
            plus: rel(m.plus),
            mic: rel(m.mic),
            send: rel(m.send),
            plusGlyph: m.plus?.glyph && m.box ? +(m.plus.glyph.left - m.box.left).toFixed(2) : null,
            rows: m.rows,
          })}`,
        );
        // The geometry is the theme's to keep: measure the light page, still both.
        if (scheme === "light") light = m;
        await page.close();
      }
      return light!;
    })();
    measured.set(layout.name, run);
    return run;
  };

  for (const layout of LAYOUTS) {
    test(`${layout.name} (${layout.look}) at ${layout.width} px: + to text gap and one left column`, async () => {
      expect(columnProblems(layout, await measureLayout(layout))).toEqual([]);
    });
    test(`${layout.name} (${layout.look}) at ${layout.width} px: +, mic and Send centered, equal insets`, async () => {
      expect(centerProblems(layout, await measureLayout(layout))).toEqual([]);
    });
  }
});
