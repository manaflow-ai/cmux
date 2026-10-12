// The New Tab page's template switch (cx-f6i7, plans/cmux-next/motion.md): when a dot picks
// another template, a part both templates show slides from where it was drawn to its new place
// (`--agent-motion-move`), a part only the new one shows fades in where it lands
// (`--agent-motion-in`), and a part only the old one showed goes at once. Cards and the list are
// different items, so they never crossfade. Only transform and opacity animate (Web Animations),
// and a switch mid-motion starts from what is on screen: places are read with the running
// transforms, then those animations are cancelled before the new layout is read.

/// The parts that move or appear, with the part they sit in (whose own slide they ride).
const PARTS: ReadonlyArray<{ name: string; selector: string; parent?: string }> = [
  { name: "box", selector: ".nt-box" },
  { name: "prompt", selector: ".nt-prompt-glyph", parent: "box" },
  { name: "field", selector: ".nt-field", parent: "box" },
  { name: "open", selector: ".nt-open-tabs:not(.nt-closed)" },
  { name: "closed", selector: ".nt-closed" },
  { name: "chats", selector: ".nt-chats" },
  { name: "chats-head", selector: ".nt-chats-head", parent: "chats" },
  { name: "chats-empty", selector: ".nt-chats-empty", parent: "chats" },
  { name: "cards", selector: ".nt-cards[data-variant=cards]", parent: "chats" },
  { name: "list", selector: ".nt-cards[data-variant=list]", parent: "chats" },
];

export type TemplatePlaces = Map<string, DOMRect>;

const running = new WeakMap<HTMLElement, Animation[]>();

function parts(screen: HTMLElement): Map<string, HTMLElement> {
  const found = new Map<string, HTMLElement>();
  for (const part of PARTS) {
    const element = screen.querySelector<HTMLElement>(part.selector);
    if (element) found.set(part.name, element);
  }
  return found;
}

/// Where each part is drawn now (running slides included), before the switch.
export function templatePlaces(screen: HTMLElement | null): TemplatePlaces {
  const places: TemplatePlaces = new Map();
  if (!screen) return places;
  for (const [name, element] of parts(screen)) places.set(name, element.getBoundingClientRect());
  return places;
}

function seconds(value: string): number {
  const text = value.trim();
  const number = Number.parseFloat(text);
  if (!Number.isFinite(number) || number <= 0) return 0;
  return text.endsWith("ms") ? number / 1000 : number;
}

/// Plays the switch on `screen` once the new template is committed, from `before`
/// (`templatePlaces` read before the commit).
export function playTemplateSwitch(screen: HTMLElement | null, before: TemplatePlaces): void {
  if (!screen || before.size === 0) return;
  for (const animation of running.get(screen) ?? []) animation.cancel();
  running.delete(screen);
  if (globalThis.matchMedia?.("(prefers-reduced-motion: reduce)").matches) return;
  const style = getComputedStyle(screen);
  const move = seconds(style.getPropertyValue("--agent-motion-move")) * 1000;
  const appear = seconds(style.getPropertyValue("--agent-motion-in")) * 1000;
  const easing = style.getPropertyValue("--agent-ease-out").trim() || "ease-out";
  // Reads: the new layout with no motion applied.
  const now = parts(screen);
  const after = new Map([...now].map(([name, element]) => [name, element.getBoundingClientRect()] as const));
  const shift = (name: string) => {
    const was = before.get(name);
    const is = after.get(name);
    return was && is ? { x: was.left - is.left, y: was.top - is.top } : undefined;
  };
  // Writes.
  const animations: Animation[] = [];
  for (const part of PARTS) {
    const element = now.get(part.name);
    if (!element) continue;
    const own = shift(part.name);
    // Inside a part that appears, it appears with it.
    if (part.parent && now.has(part.parent) && !before.has(part.parent)) continue;
    if (!own) {
      if (appear > 0) animations.push(element.animate([{ opacity: 0 }, { opacity: 1 }], { duration: appear, easing }));
      continue;
    }
    const carried = part.parent ? shift(part.parent) : undefined;
    const x = own.x - (carried?.x ?? 0);
    const y = own.y - (carried?.y ?? 0);
    if (move > 0 && (Math.abs(x) > 0.5 || Math.abs(y) > 0.5)) {
      animations.push(
        element.animate([{ transform: `translate(${x}px, ${y}px)` }, { transform: "none" }], {
          duration: move,
          easing,
        }),
      );
    }
  }
  if (animations.length > 0) running.set(screen, animations);
}
