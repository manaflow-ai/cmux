// The detector for "a link state moved the content" (Leo, 2026-11-21: "stop layout shifting"; the rule is the
// desktop's and the web's as much as the phone's). jsdom has no layout, so this does not measure boxes: it checks
// the one thing that decides whether a state can move them, structurally. A surface drawn in each of its states
// must have the same IN-FLOW skeleton: every element that is not `position: absolute|fixed` (and not under one)
// is listed with its tag, classes and declared height, and the lists of all states must be equal. A line that
// appears as a row in one state adds an entry the connected state lacks and fails; a chip drawn out of flow, in a
// box that is there in every state, adds none and passes. bench/host-line-shift.bench.ts is the same check in
// Chromium with real boxes, and gives the number in px.
//
// Reuse (a pane, a sheet, any surface with a link, loading or error state):
//   const css = cssRules(readFileSync("src/…/styles.css", "utf8"), /my-surface/);   // rules the states use
//   const { signature } = await drawStates(document, css, { connected: () => draw(...), offline: () => draw(...) });
//   expectSameFlow(signature)                       // throws naming the first state and the entry that differs
//   expectOutOfFlow(document.querySelector(".my-chip")!)
// `draw` renders the state into the document (inside act, for React). styles are real CSS, so a rule that puts
// the chip back in flow fails the test.
import type { JSDOM } from "jsdom";

/// The rules of `css` whose selector matches `selector`, as text jsdom can load: top-level `a{b}` rules, one
/// level of `@media`/`@keyframes` is dropped (jsdom ignores them for layout). Enough to bring a surface's own
/// styles into a document without 170 KB of unrelated rules.
export function cssRules(source: string, selector: RegExp): string {
  const css = source.replace(/\/\*[\s\S]*?\*\//g, "");
  const kept: string[] = [];
  let depth = 0;
  let start = 0;
  let head = "";
  for (let index = 0; index < css.length; index++) {
    const char = css[index];
    if (char === "{") {
      if (depth === 0) head = css.slice(start, index).trim();
      depth++;
    } else if (char === "}") {
      depth--;
      if (depth === 0) {
        const text = css.slice(start, index + 1).trim();
        if (!head.startsWith("@") && selector.test(head)) kept.push(text);
        start = index + 1;
      }
    }
  }
  return kept.join("\n");
}

/// Whether `element` is out of its parent's flow: absolutely or fixed positioned, by the loaded styles.
export function isOutOfFlow(element: Element): boolean {
  const view = element.ownerDocument.defaultView;
  const position = view?.getComputedStyle(element).position;
  return position === "absolute" || position === "fixed";
}

/// Throws unless `element` is out of flow (see `isOutOfFlow`).
export function expectOutOfFlow(element: Element): void {
  if (!isOutOfFlow(element))
    throw new Error(
      `${describe(element)} is in flow: showing it adds a row and moves the content. Draw it position: absolute/fixed, in a box that is in every state.`,
    );
}

function describe(element: Element): string {
  const cls =
    typeof element.className === "string" ? element.className.trim().split(/\s+/).filter(Boolean).join(".") : "";
  return `${element.tagName.toLowerCase()}${cls ? `.${cls}` : ""}`;
}

/// The in-flow skeleton of `root`: one line per element that takes part in layout, in document order, with its
/// declared height (what a reserved slot pins). Out-of-flow elements and everything inside them are left out:
/// they move nothing. Text is not listed: a state's words may differ; where they sit may not.
export function flowSignature(root: Element): string[] {
  const view = root.ownerDocument.defaultView;
  const lines: string[] = [];
  const walk = (element: Element, depth: number) => {
    const style = view?.getComputedStyle(element);
    if (style?.display === "none" || isOutOfFlow(element)) return;
    const height = style?.height && style.height !== "auto" ? ` h=${style.height}` : "";
    lines.push(`${"  ".repeat(depth)}${describe(element)}${height}`);
    for (const child of Array.from(element.children)) walk(child, depth + 1);
  };
  for (const child of Array.from(root.children)) walk(child, 0);
  return lines;
}

/// Loads `css` into `dom`'s document once.
export function loadStyles(dom: JSDOM, css: string): void {
  const document = dom.window.document;
  const style = document.createElement("style");
  style.textContent = css;
  document.head.append(style);
}

/// Draws each state in turn (`draw` renders it into the document) and returns its in-flow skeleton, by name.
export async function drawStates(
  root: Element,
  states: Record<string, () => void | Promise<void>>,
): Promise<Record<string, string[]>> {
  const signature: Record<string, string[]> = {};
  for (const [name, draw] of Object.entries(states)) {
    await draw();
    signature[name] = flowSignature(root);
  }
  return signature;
}

/// Throws, naming the state and the first differing line, unless every state has the first state's skeleton.
export function expectSameFlow(signature: Record<string, string[]>): void {
  const [[firstName, first], ...rest] = Object.entries(signature) as [string, string[]][];
  for (const [name, lines] of rest) {
    const at = lines.findIndex((line, index) => line !== first[index]);
    if (at === -1 && lines.length === first.length) continue;
    const index = at === -1 ? Math.min(lines.length, first.length) : at;
    throw new Error(
      `layout shift: state "${name}" differs from "${firstName}" in flow at line ${index}: ` +
        `${JSON.stringify(first[index] ?? "(none)")} vs ${JSON.stringify(lines[index] ?? "(none)")}`,
    );
  }
}
