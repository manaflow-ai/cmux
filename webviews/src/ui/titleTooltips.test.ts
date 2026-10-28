// Leo, 2026-10-12: a tooltip for truncated text was narrower than the row it came from, so the
// full text wrapped into a tall thin column. A tooltip for truncated text shows the full text,
// wrapping, up to the source row's width (at least ~480 px), and never narrower than the line.
// Tooltips also carry a shortcut hint in the secondary ink, like the native one.
import { afterEach, expect, jest, test } from "bun:test";
import { JSDOM } from "jsdom";
import { HoverGroup, HoverIntent } from "./hoverIntent";
import { installTooltips, tooltipPosition, tooltipWidth } from "./titleTooltips";

test("a tooltip for truncated text wraps up to its source's width, never narrower than the line", () => {
  // Untruncated: the standard tooltip width.
  expect(tooltipWidth({ width: 120, truncated: false, view: 1000 })).toEqual({ min: 0, max: 320 });
  // A truncated 600 px line: at least the line, wrapping up to it.
  expect(tooltipWidth({ width: 600, truncated: true, view: 1000 })).toEqual({ min: 600, max: 600 });
  // A narrow truncated chip: up to 480 px.
  expect(tooltipWidth({ width: 140, truncated: true, view: 1000 })).toEqual({ min: 140, max: 480 });
  // Never wider than the window's room.
  expect(tooltipWidth({ width: 900, truncated: true, view: 700 })).toEqual({ min: 688, max: 688 });
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

test("hovering a truncated row shows its full text as wide as the row", async () => {
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
  expect(tip.style.minWidth).toBe("600px");
  expect(tip.style.maxWidth).toBe("600px");
});

test("a short title's tooltip for truncated text is only as wide as its text", () => {
  // The line is 600 px but the full text measures 250 px: no wide empty box.
  expect(tooltipWidth({ width: 600, truncated: true, view: 1000, text: 250 })).toEqual({ min: 250, max: 600 });
  // Text longer than the line: at least the line, as before.
  expect(tooltipWidth({ width: 600, truncated: true, view: 1000, text: 2000 })).toEqual({ min: 600, max: 600 });
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
  expect(tip.style.minWidth).toBe("330px");
  expect(tip.style.maxWidth).toBe("600px");
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
  const toolbarHint = new HoverIntent<string>({ group, clock, show: (id) => hint.push(id), hide: () => {} });
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
    return { left, top: 0, width: Math.min(7 * (this.textContent ?? "").length, 1000 - left), height: 16 } as DOMRect;
  };
  try {
    const tip = doc.querySelector<HTMLElement>(".ui-title-tooltip")!;
    await hover(close);
    expect(tip.style.left).toBe(`${1000 - 6 - 35}px`);
    close.dispatchEvent(new dom!.window.MouseEvent("pointerout", { bubbles: true }));
    await hover(summary);
    expect(tip.textContent).toBe("Chat summary");
    // As wide as its text (84 px), not squeezed into the 41 px right of the last tooltip's place.
    expect(tip.style.left).toBe(`${1000 - 6 - 84}px`);
  } finally {
    proto.getBoundingClientRect = original;
  }
});

test("a top-side tooltip (a message's time) sits above its element, below only when there is no room above", () => {
  const view = { width: 800, height: 600 };
  const size = { width: 140, height: 22 };
  const time = { left: 100, top: 300, width: 80, height: 24 };
  // Centered on the time, 6px above it (as Claude's), and below by default.
  expect(tooltipPosition(time, size, view, "top")).toEqual({ left: 70, top: 272 });
  expect(tooltipPosition(time, size, view)).toEqual({ left: 70, top: 330 });
  // At the pane's top edge: below.
  expect(tooltipPosition({ ...time, top: 10 }, size, view, "top")).toEqual({ left: 70, top: 40 });
});
