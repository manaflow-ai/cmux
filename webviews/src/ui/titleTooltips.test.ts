// Tooltips reveal the full label in a compact bubble, independent of the source row width.
import { afterEach, expect, jest, test } from "bun:test";
import { JSDOM } from "jsdom";
import { HoverGroup, HoverIntent } from "./hoverIntent";
import { installTooltips, tooltipPosition, tooltipWidth, UI_TOOLTIP_EDGE, UI_TOOLTIP_MAX_WIDTH } from "./titleTooltips";
import { UI_TOOLTIP_GAP } from "./tooltipTokens";
import { setPopupInsetTop } from "./popupInset";

test("full labels stay content-sized and bounded even on wide truncated rows", () => {
  for (const width of [140, 600, 900]) {
    for (const truncated of [false, true]) {
      expect(tooltipWidth({ width, truncated, view: 1000 })).toEqual({ min: 0, max: 320 });
    }
  }
  expect(tooltipWidth({ width: 900, truncated: true, view: 200 })).toEqual({ min: 0, max: 192 });
  expect(tooltipWidth({ width: 900, truncated: true, view: 1000, scale: 1.25 })).toEqual({
    min: 0,
    max: 400,
  });
});

let dom: JSDOM | undefined;
let uninstall: (() => void) | undefined;
afterEach(() => {
  uninstall?.();
  dom?.window.close();
  uninstall = undefined;
  dom = undefined;
});

/** Hovers `element` and waits a frame: the tooltip shows on the next one. */
async function hover(element: Element) {
  element.dispatchEvent(new dom!.window.MouseEvent("pointerover", { bubbles: true }));
  await new Promise((resolve) => dom!.window.requestAnimationFrame(resolve));
}

/** A page with title tooltips; the layout tests show them with no hover delay (the delay is tested below). */
function page(body: string, options: Parameters<typeof installTooltips>[1] = { delay: 0 }) {
  dom = new JSDOM(`<!doctype html><body>${body}</body>`, { pretendToBeVisual: true });
  Object.defineProperty(dom.window.document.documentElement, "clientWidth", { value: 1000 });
  Object.defineProperty(dom.window.document.documentElement, "clientHeight", { value: 800 });
  uninstall = installTooltips(dom.window.document, options);
  return dom.window.document;
}

test("hovering a truncated row shows its full text without adopting the row width", async () => {
  const doc = page(
    `<div id="row" title="A long chat title that the sidebar row cuts off with an ellipsis">A long…</div>`,
  );
  const row = doc.getElementById("row")!;
  Object.defineProperty(row, "scrollWidth", { value: 900 });
  Object.defineProperty(row, "clientWidth", { value: 600 });
  row.getBoundingClientRect = () => ({ left: 10, top: 10, width: 600, height: 24 }) as DOMRect;
  await hover(row);
  const tip = doc.querySelector<HTMLElement>(".ui-title-tooltip")!;
  expect(tip.hidden).toBe(false);
  expect(tip.textContent).toBe("A long chat title that the sidebar row cuts off with an ellipsis");
  expect(tip.style.minWidth).toBe("0px");
  expect(tip.style.maxWidth).toBe("320px");
});

test("a short title's tooltip for truncated text is only as wide as its text", () => {
  // The source and text never impose a minimum width.
  expect(tooltipWidth({ width: 600, truncated: true, view: 1000, text: 250 })).toEqual({
    min: 0,
    max: 320,
  });
  // Long text wraps and stays fully available.
  expect(tooltipWidth({ width: 600, truncated: true, view: 1000, text: 2000 })).toEqual({
    min: 0,
    max: 320,
  });
});

test("a row whose child clips its text gets the truncated tooltip, sized to the text", async () => {
  // BranchBasePicker: the title sits on the row, the primary label inside it clips.
  const doc = page(
    `<div id="row" title="feature/a-branch-name-the-picker-row-cuts-off"><span id="primary">feature/a-bra…</span><span>2d</span></div>`,
  );
  const row = doc.getElementById("row")!;
  Object.defineProperty(row, "scrollWidth", { value: 600 });
  Object.defineProperty(row, "clientWidth", { value: 600 });
  const primary = doc.getElementById("primary")!;
  Object.defineProperty(primary, "scrollWidth", { value: 900 });
  Object.defineProperty(primary, "clientWidth", { value: 400 });
  row.getBoundingClientRect = () => ({ left: 10, top: 10, width: 600, height: 28 }) as DOMRect;
  // The tooltip's own text, laid out on one line, measures 330 px.
  const proto = dom!.window.HTMLElement.prototype;
  const original = proto.getBoundingClientRect;
  proto.getBoundingClientRect = function (this: HTMLElement) {
    if (this.classList.contains("ui-title-tooltip")) return { left: 0, top: 0, width: 330, height: 16 } as DOMRect;
    return original.call(this);
  };
  await hover(row);
  const tip = doc.querySelector<HTMLElement>(".ui-title-tooltip")!;
  expect(tip.hidden).toBe(false);
  expect(tip.style.minWidth).toBe("0px");
  expect(tip.style.maxWidth).toBe("320px");
});

test("an untruncated control's tooltip keeps the standard width and shows its shortcut hint", async () => {
  const doc = page(`<button id="new" title="New Tab" data-tooltip-shortcut="⌘T"></button>`);
  const button = doc.getElementById("new")!;
  button.getBoundingClientRect = () => ({ left: 10, top: 10, width: 24, height: 24 }) as DOMRect;
  await hover(button);
  const tip = doc.querySelector<HTMLElement>(".ui-title-tooltip")!;
  expect(tip.hidden).toBe(false);
  expect(tip.style.maxWidth).toBe("320px");
  expect(tip.querySelector(".ui-tooltip-text")?.textContent).toBe("New Tab");
  expect(tip.querySelector(".ui-tooltip-hint")?.textContent).toBe("⌘T");
});

test("rows passing under a scroll do not flash their tooltips; the row under the pointer shows once it stops", async () => {
  // Review of #19902: with no hover delay, scrolling a list under a resting pointer flashed each row's tooltip.
  const doc = page(`<div id="a" title="First">a</div><div id="b" title="Second">b</div>`);
  const [a, b] = [doc.getElementById("a")!, doc.getElementById("b")!];
  for (const row of [a, b])
    row.getBoundingClientRect = () => ({ left: 10, top: 10, width: 200, height: 24 }) as DOMRect;
  const tip = () => doc.querySelector<HTMLElement>(".ui-title-tooltip")!;
  await hover(a);
  expect(tip().hidden).toBe(false);
  // The scroll's quiet time and the frames after it run on a clock the test moves.
  jest.useFakeTimers();
  try {
    doc.dispatchEvent(new dom!.window.Event("scroll"));
    a.dispatchEvent(new dom!.window.MouseEvent("pointerout", { bubbles: true, relatedTarget: b }));
    b.dispatchEvent(new dom!.window.MouseEvent("pointerover", { bubbles: true }));
    // Inside the scroll's quiet time (150 ms) the row under the pointer shows nothing.
    jest.advanceTimersByTime(100);
    expect(tip().hidden).toBe(true);
    jest.advanceTimersByTime(300);
    expect(tip().hidden).toBe(false);
    expect(tip().querySelector(".ui-tooltip-text")?.textContent).toBe("Second");
  } finally {
    jest.useRealTimers();
  }
});

// Leo, 2026-10-14: tooltips showed at once on every control the pointer passed. They wait the hover
// delay (450 ms, ui/hoverIntent.ts) before the first, then show at once for a neighbor while the
// group is warm, and cool 500 ms after the last one hid. A control whose own text says the tooltip
// shows none (#20375). The timers run on a clock the test moves.
class FakeClock {
  now = 0;
  private timers: { at: number; run: () => void; id: number }[] = [];
  private next = 1;
  set = (run: () => void, ms: number) => {
    const id = this.next++;
    this.timers.push({ at: this.now + ms, run, id });
    return id;
  };
  clear = (id: unknown) => {
    this.timers = this.timers.filter((timer) => timer.id !== id);
  };
  advance(ms: number) {
    const end = this.now + ms;
    for (;;) {
      const due = this.timers.filter((timer) => timer.at <= end).sort((a, b) => a.at - b.at)[0];
      if (!due) break;
      this.timers = this.timers.filter((timer) => timer !== due);
      this.now = due.at;
      due.run();
    }
    this.now = end;
  }
}

function toolbar(clock: FakeClock) {
  const labels = ["Back", "Forward", "Reload", "Share", "Downloads"];
  const doc = page(labels.map((label, index) => `<button id="b${index}" title="${label}"></button>`).join(""), {
    clock,
  });
  const buttons = labels.map((_, index) => doc.getElementById(`b${index}`)!);
  buttons.forEach((button, index) => {
    button.getBoundingClientRect = () => ({ left: 10 + index * 30, top: 10, width: 24, height: 24 }) as DOMRect;
  });
  const tip = () => doc.querySelector<HTMLElement>(".ui-title-tooltip")!;
  const text = () => (tip().hidden ? null : (tip().querySelector(".ui-tooltip-text")?.textContent ?? null));
  return { doc, buttons, text };
}

async function leave(element: Element, into: Element | null = null) {
  element.dispatchEvent(new dom!.window.MouseEvent("pointerout", { bubbles: true, relatedTarget: into }));
  await new Promise((resolve) => dom!.window.requestAnimationFrame(resolve));
}

test("the first tooltip waits the hover delay; a neighbor's then shows at once until the group cools", async () => {
  const clock = new FakeClock();
  const { buttons, text } = toolbar(clock);
  await hover(buttons[0]);
  expect(text()).toBeNull();
  clock.advance(300);
  await hover(buttons[0]);
  expect(text()).toBeNull();
  clock.advance(200);
  await new Promise((resolve) => dom!.window.requestAnimationFrame(resolve));
  expect(text()).toBe("Back");
  // Warm: straight to the neighbor, its tooltip at once.
  await leave(buttons[0], buttons[1]);
  await hover(buttons[1]);
  expect(text()).toBe("Forward");
  // Off the toolbar for less than the warm time: still at once.
  await leave(buttons[1]);
  expect(text()).toBeNull();
  clock.advance(200);
  await hover(buttons[2]);
  expect(text()).toBe("Reload");
  // Away past the warm time: the next waits the full delay again.
  await leave(buttons[2]);
  clock.advance(600);
  await hover(buttons[3]);
  expect(text()).toBeNull();
  clock.advance(850);
  await new Promise((resolve) => dom!.window.requestAnimationFrame(resolve));
  expect(text()).toBe("Share");
});

test("a fast sweep across a toolbar shows no tooltip", async () => {
  const clock = new FakeClock();
  const { buttons, text } = toolbar(clock);
  const seen: string[] = [];
  for (const [index, button] of buttons.entries()) {
    await hover(button);
    clock.advance(60);
    const shown = text();
    if (shown) seen.push(shown);
    await leave(button, buttons[index + 1] ?? null);
  }
  clock.advance(1500);
  await new Promise((resolve) => dom!.window.requestAnimationFrame(resolve));
  const shown = text();
  if (shown) seen.push(shown);
  expect(seen).toEqual([]);
});

test("a control whose own text says the tooltip shows none", async () => {
  const clock = new FakeClock();
  const doc = page(`<button id="reload" title="Reload">Reload</button><button id="icon" title="Back"></button>`, {
    clock,
  });
  for (const id of ["reload", "icon"])
    doc.getElementById(id)!.getBoundingClientRect = () => ({ left: 10, top: 10, width: 60, height: 24 }) as DOMRect;
  const tip = () => doc.querySelector<HTMLElement>(".ui-title-tooltip")!;
  await hover(doc.getElementById("reload")!);
  clock.advance(2000);
  await new Promise((resolve) => dom!.window.requestAnimationFrame(resolve));
  expect(tip().hidden).toBe(true);
  // An icon-only control still shows its own.
  await leave(doc.getElementById("reload")!, doc.getElementById("icon"));
  await hover(doc.getElementById("icon")!);
  clock.advance(2000);
  await new Promise((resolve) => dom!.window.requestAnimationFrame(resolve));
  expect(tip().hidden).toBe(false);
  expect(tip().querySelector(".ui-tooltip-text")?.textContent).toBe("Back");
});

test("a key typed while a toolbar hint waits drops it: it does not pop up mid-typing", async () => {
  const clock = new FakeClock();
  const group = new HoverGroup(500, clock);
  const doc = page(`<button id="b" title="Back"></button>`, { clock, group });
  // A toolbar hint (ui/Toolbar.tsx) in the same group, waiting its delay.
  const hint: string[] = [];
  const toolbarHint = new HoverIntent<string>({
    group,
    clock,
    show: (id) => hint.push(id),
    hide: () => {},
  });
  toolbarHint.hover("Share");
  clock.advance(200);
  doc.dispatchEvent(new dom!.window.KeyboardEvent("keydown", { key: "a", bubbles: true }));
  clock.advance(2000);
  expect(hint).toEqual([]);
});

// Leo, 2026-10-20: the chat header's "Chat summary" tooltip, at the window's right edge, read
// "Chat summar / y". The fixed tooltip kept the place of the last one shown (a shorter one, further
// right) while it was measured, so its shrink-to-fit width was only the room right of that place,
// and the text broke inside a word.
test("a tooltip near the right edge is measured at its full width, wherever the last one stood", async () => {
  const doc = page(`<button id="close" title="Close"></button><button id="summary" title="Chat summary"></button>`);
  const close = doc.getElementById("close")!;
  const summary = doc.getElementById("summary")!;
  close.getBoundingClientRect = () => ({ left: 970, top: 10, width: 24, height: 24 }) as DOMRect;
  summary.getBoundingClientRect = () => ({ left: 940, top: 10, width: 26, height: 26 }) as DOMRect;
  // Laid out on one line its text is 7 px a letter, but a fixed box only gets the room right of its `left`.
  const proto = dom!.window.HTMLElement.prototype;
  const original = proto.getBoundingClientRect;
  proto.getBoundingClientRect = function (this: HTMLElement) {
    if (!this.classList.contains("ui-title-tooltip")) return original.call(this);
    const left = parseFloat(this.style.left) || 0;
    return {
      left,
      top: 0,
      width: Math.min(7 * (this.textContent ?? "").length, 1000 - left),
      height: 16,
    } as DOMRect;
  };
  try {
    const tip = doc.querySelector<HTMLElement>(".ui-title-tooltip")!;
    await hover(close);
    expect(tip.style.left).toBe(`${1000 - UI_TOOLTIP_EDGE - 35}px`);
    close.dispatchEvent(new dom!.window.MouseEvent("pointerout", { bubbles: true }));
    await hover(summary);
    expect(tip.textContent).toBe("Chat summary");
    // The full 84px label now fits centered on the trigger, before the 4px edge clamp.
    expect(tip.style.left).toBe(`${940 + 26 / 2 - 84 / 2}px`);
    expect(tip.getBoundingClientRect().width).toBe(84);
  } finally {
    proto.getBoundingClientRect = original;
  }
});

test("a top-side tooltip (a message's time) sits above its element, below only when there is no room above", () => {
  const view = { width: 800, height: 600 };
  const size = { width: 140, height: 22 };
  const time = { left: 100, top: 300, width: 80, height: 24 };
  // Centered on the time, on the compact 4px grid gap above it (as Claude's), and above by default.
  expect(tooltipPosition(time, size, view, "top")).toEqual({ left: 70, top: 274 });
  expect(tooltipPosition(time, size, view)).toEqual({ left: 70, top: 274 });
  // At the pane's top edge: below.
  expect(tooltipPosition({ ...time, top: 10 }, size, view, "top")).toEqual({ left: 70, top: 38 });
  const scaled = tooltipPosition(time, size, view, "top", 1.5);
  expect(time.top - (scaled.top + size.height)).toBe(UI_TOOLTIP_GAP * 1.5);
  expect(UI_TOOLTIP_GAP).toBe(4);
  expect(UI_TOOLTIP_EDGE).toBe(UI_TOOLTIP_GAP);
  expect(UI_TOOLTIP_MAX_WIDTH).toBe(320);
  const positioned = tooltipPosition(time, size, view);
  expect(time.top - (positioned.top + size.height)).toBe(UI_TOOLTIP_GAP);
});

test("a tooltip stays inside its region: above when it fits there, else below, else the window's edges", () => {
  const view = { width: 1000, height: 800 };
  const size = { width: 240, height: 36 };
  // The transcript below a 40px band the native tabs draw over.
  const bounds = { left: 0, top: 40, width: 1000, height: 760 };
  const row = { left: 50, top: 48, width: 200, height: 22 };
  // The window has room above (8px), the region has none: below the row.
  expect(tooltipPosition(row, size, view, "top")).toEqual({ left: 30, top: 8 });
  expect(tooltipPosition(row, size, view, "top", 1, bounds)).toEqual({ left: 30, top: 74 });
  // Lower down there is room above inside the region: above, as everywhere.
  expect(tooltipPosition({ ...row, top: 300 }, size, view, "top", 1, bounds)).toEqual({ left: 30, top: 260 });
  // A region too small for it either way: the window's edges, as before.
  const tiny = { left: 0, top: 40, width: 1000, height: 40 };
  expect(tooltipPosition(row, size, view, "top", 1, tiny)).toEqual({ left: 30, top: 8 });
});

test("a pane-wide row's tooltip anchors at its words and stays out of the tab row the native tabs cover", async () => {
  // A one-tab pane (header.css data-solo-tab): the transcript runs up under the tab row.
  const doc = page(
    `<header id="tabs" data-tooltip-covered></header>` +
      `<div id="scroll" style="overflow-y: auto"><button id="row" title="Claude Code 2.1.312 · claude-opus-5-5 · your Claude Code setup · ~/Projects"><span>Claude Code · Opus 5.5</span></button></div>`,
  );
  const box = (left: number, top: number, width: number, height: number) =>
    ({ left, top, width, height, right: left + width, bottom: top + height }) as DOMRect;
  doc.getElementById("tabs")!.getBoundingClientRect = () => box(0, 0, 1000, 40);
  doc.getElementById("scroll")!.getBoundingClientRect = () => box(0, 0, 1000, 800);
  const row = doc.getElementById("row")!;
  row.getBoundingClientRect = () => box(50, 48, 900, 22);
  const tip = doc.querySelector<HTMLElement>(".ui-title-tooltip")!;
  tip.getBoundingClientRect = () => box(0, 0, 240, 36);
  // What the row draws: its icon, words and chevron, 200px of the 900.
  // jsdom lays nothing out, so its Range has no geometry of its own: this page's gets the words' box.
  Object.defineProperty(dom!.window.Range.prototype, "getBoundingClientRect", {
    configurable: true,
    value: () => box(50, 50, 200, 18),
  });
  await hover(row);
  expect(tip.hidden).toBe(false);
  // Centered on the words (50 + 100 - 120), not on the row's middle (50 + 450 - 120 = 380), and
  // below the row, not above it under the tabs (48 - 4 - 36 = 8).
  expect(tip.style.left).toBe("30px");
  expect(tip.style.top).toBe(`${48 + 22 + UI_TOOLTIP_GAP}px`);
});

/// Leo, 2026-11-07 (Trace-ID ask-11b77f340e): closing a tab in a tight pane moved the chat's tools up under a pointer
/// that did not move. An element the page lays out under a still pointer gets the engine's `pointerover` too; its
/// tooltip waits for the pointer to move, and then shows for what is under it.
test("a layout that moves a control under a still pointer shows nothing until the pointer moves", async () => {
  const doc = page(`<button id="tool" title="Session Info"></button><div id="rest"></div>`);
  const tool = doc.getElementById("tool")!;
  const at = (type: string, target: Element, x: number) =>
    target.dispatchEvent(new dom!.window.MouseEvent(type, { bubbles: true, screenX: x, screenY: 40 }));
  // The pointer rests over the row's empty part.
  at("pointerover", doc.getElementById("rest")!, 500);
  at("pointermove", doc.getElementById("rest")!, 500);
  // The tools land under it: the same point, no move.
  at("pointerover", tool, 500);
  await new Promise((resolve) => dom!.window.requestAnimationFrame(resolve));
  const tip = doc.querySelector<HTMLElement>(".ui-title-tooltip");
  expect(tip === null || tip.hidden).toBe(true);
  // An engine's synthetic move at the same point is no move either.
  at("pointermove", tool, 500);
  await new Promise((resolve) => dom!.window.requestAnimationFrame(resolve));
  expect(doc.querySelector<HTMLElement>(".ui-title-tooltip")?.hidden ?? true).toBe(true);
  // A real move over the tool shows its tooltip.
  at("pointermove", tool, 502);
  await new Promise((resolve) => dom!.window.requestAnimationFrame(resolve));
  expect(doc.querySelector<HTMLElement>(".ui-title-tooltip")?.hidden).toBe(false);
  expect(doc.querySelector<HTMLElement>(".ui-title-tooltip")?.textContent).toBe("Session Info");
});

test("a timestamp's tooltip under an open Find bar flips below its row, never over the bar", async () => {
  // Leo 2026-11-07: a message time's "Nov 7, 2026, 12:05 AM" drawn over the find bar. The bar
  // (ChatFindBar.tsx) registers its bottom, 52px down, in ui/popupInset.ts while it shows.
  const doc = page(
    `<div id="scroll" style="overflow-y: auto"><time id="time" title="Nov 7, 2026, 12:05 AM">12:05 AM</time></div>`,
  );
  const box = (left: number, top: number, width: number, height: number) =>
    ({ left, top, width, height, right: left + width, bottom: top + height }) as DOMRect;
  doc.getElementById("scroll")!.getBoundingClientRect = () => box(0, 0, 1000, 800);
  const time = doc.getElementById("time")!;
  time.getBoundingClientRect = () => box(800, 60, 60, 18);
  const tip = doc.querySelector<HTMLElement>(".ui-title-tooltip")!;
  tip.getBoundingClientRect = () => box(0, 0, 160, 24);
  setPopupInsetTop(52, "findBar");
  try {
    await hover(time);
    expect(tip.hidden).toBe(false);
    // Above would be 60 - 4 - 24 = 32, under the bar: it goes below the time instead.
    expect(tip.style.top).toBe(`${60 + 18 + UI_TOOLTIP_GAP}px`);
  } finally {
    setPopupInsetTop(0, "findBar");
  }
});

test("a header control's tooltip above an open Find bar starts below the bar", () => {
  // next-review F3 at e03f60d5: a control at y=2-26 with Find down to y=72 put its tooltip at y=30.
  const bounds = { left: 0, top: 76, width: 1000, height: 724 };
  const placed = tooltipPosition(
    { left: 900, top: 2, width: 24, height: 24 },
    { width: 120, height: 24 },
    { width: 1000, height: 800 },
    "top",
    1,
    bounds,
  );
  expect(placed.top).toBeGreaterThanOrEqual(76);
});

test("a tooltip already open when the Find bar opens goes away", async () => {
  // router-review follow-up at e03f60d5: native Cmd-F reaches the page as no key, so the bar's own
  // inset change (ChatFindBar.tsx) is what takes the tooltip away.
  const doc = page(
    `<div id="scroll" style="overflow-y: auto"><time id="time" title="Nov 7, 2026, 12:05 AM">12:05 AM</time></div>`,
  );
  const box = (left: number, top: number, width: number, height: number) =>
    ({ left, top, width, height, right: left + width, bottom: top + height }) as DOMRect;
  doc.getElementById("scroll")!.getBoundingClientRect = () => box(0, 0, 1000, 800);
  const time = doc.getElementById("time")!;
  time.getBoundingClientRect = () => box(800, 60, 60, 18);
  const tip = doc.querySelector<HTMLElement>(".ui-title-tooltip")!;
  tip.getBoundingClientRect = () => box(0, 0, 160, 24);
  await hover(time);
  expect(tip.hidden).toBe(false);
  try {
    // The inset's listeners run as it is set: the tooltip leaves (or starts its fade) in that turn.
    setPopupInsetTop(52, "findBar");
    expect(tip.hidden || tip.hasAttribute("data-ending-style")).toBe(true);
  } finally {
    setPopupInsetTop(0, "findBar");
  }
});

// Lucas 2026-11-11: a model menu row's cut name shows in full at once, not after the hover delay.
test("a data-tooltip-instant element shows its tooltip with no hover delay", async () => {
  const clock = new FakeClock();
  const doc = page(
    `<button id="cold" title="Back"></button><span id="name" title="DeepSeek V4.1 Flash" data-tooltip-instant=""></span>`,
    {
      clock,
    },
  );
  for (const id of ["cold", "name"]) {
    doc.getElementById(id)!.getBoundingClientRect = () => ({ left: 10, top: 10, width: 24, height: 24 }) as DOMRect;
  }
  const tip = () => doc.querySelector<HTMLElement>(".ui-title-tooltip")!;
  const text = () => (tip().hidden ? null : (tip().querySelector(".ui-tooltip-text")?.textContent ?? null));
  // A cold group: a plain title waits; the instant one shows on the next frame, with no time passing.
  await hover(doc.getElementById("cold")!);
  expect(text()).toBeNull();
  await leave(doc.getElementById("cold")!);
  await hover(doc.getElementById("name")!);
  expect(text()).toBe("DeepSeek V4.1 Flash");
});

// Lucas 2026-11-11: a model name the row's star draws over shows in full at once, though the row does not cut it.
test("a data-tooltip-force element shows its tooltip even when its text is in full view", async () => {
  const doc = page(
    `<span id="name" title="Sonnet" data-tooltip-instant="" data-tooltip-force="">Sonnet</span><span id="plain" title="Opus" data-tooltip-instant="">Opus</span>`,
  );
  for (const id of ["name", "plain"]) {
    doc.getElementById(id)!.getBoundingClientRect = () => ({ left: 10, top: 10, width: 40, height: 20 }) as DOMRect;
  }
  const tip = () => doc.querySelector<HTMLElement>(".ui-title-tooltip")!;
  const text = () => (tip().hidden ? null : (tip().querySelector(".ui-tooltip-text")?.textContent ?? null));
  // Its own text in full view and no force: no tooltip.
  await hover(doc.getElementById("plain")!);
  expect(text()).toBeNull();
  await leave(doc.getElementById("plain")!);
  await hover(doc.getElementById("name")!);
  expect(text()).toBe("Sonnet");
});
