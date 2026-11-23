// A detector for one class of update loop: a component that, during render, sets one state from two
// separate guarded `if (...) setX(...)` lines. Each line looks safe alone, but when one undoes the
// other the pane renders, sets, renders again and can loop until React gives up (#185 / #301) and the
// pane boundary shows "The agent pane could not be drawn" (Leo, 2026-11-22: "it gave me the agent pane
// could not be drawn after i opedn up background tasks"). The fix is one idempotent step: compute the
// next value with a pure function whose result is a fixed point, and set it once when it differs
// (backgroundTasks/backgroundPane.ts `backgroundPanelFor`).
import { describe, expect, test } from "bun:test";
import { readdirSync, readFileSync } from "node:fs";
import { join, relative } from "node:path";
import { backgroundPanelFor } from "../src/agent-session/acpmux/backgroundTasks/backgroundPane";

const ROOT = join(import.meta.dir, "..", "src");
/// Two render-phase sets of one state this close together belong to one adjustment.
const NEAR_LINES = 20;

function sources(dir: string, out: string[] = []): string[] {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) sources(path, out);
    else if (entry.name.endsWith(".tsx") && !entry.name.endsWith(".test.tsx") && !entry.name.endsWith(".gallery.tsx"))
      out.push(path);
  }
  return out;
}

/// The render-phase guarded sets in `text`: an `if (...)` at a component body's own indent (two
/// spaces) whose statement is `setX(...)`, on its line or the next.
function renderPhaseSets(text: string): { setter: string; line: number }[] {
  const lines = text.split("\n");
  const found: { setter: string; line: number }[] = [];
  lines.forEach((line, index) => {
    if (!/^ {2}if \(/.test(line)) return;
    const same = /\)\s*(set[A-Z]\w*)\(/.exec(line);
    const next = !same && /^ {4}(set[A-Z]\w*)\(/.exec(lines[index + 1] ?? "");
    const setter = same?.[1] ?? (next ? next[1] : undefined);
    if (setter) found.push({ setter, line: index + 1 });
  });
  return found;
}

/// Pairs of render-phase sets of one state within NEAR_LINES of each other.
function renderPhasePairs(text: string): string[] {
  const sets = renderPhaseSets(text);
  const pairs: string[] = [];
  for (let a = 0; a < sets.length; a += 1)
    for (let b = a + 1; b < sets.length; b += 1)
      if (sets[a].setter === sets[b].setter && sets[b].line - sets[a].line <= NEAR_LINES)
        pairs.push(`${sets[a].setter} at lines ${sets[a].line} and ${sets[b].line}`);
  return pairs;
}

describe("render-phase set pairs", () => {
  test("the detector finds the pair that kept the Background tasks split from drawing", () => {
    const before = [
      "function App() {",
      "  const [panel, setBackgroundPanel] = useState();",
      "  if (panel && snapshot.sessionId !== panel.sessionId) setBackgroundPanel(undefined);",
      "  const [own, setOwn] = useState(false);",
      "  if (own && !panel && snapshot.sessionId)",
      "    setBackgroundPanel({ sessionId: snapshot.sessionId });",
      "}",
    ].join("\n");
    expect(renderPhasePairs(before)).toEqual(["setBackgroundPanel at lines 3 and 5"]);
  });

  test("no component sets one state from two separate guarded lines during render", () => {
    const found: string[] = [];
    for (const path of sources(ROOT))
      for (const pair of renderPhasePairs(readFileSync(path, "utf8"))) found.push(`${relative(ROOT, path)}: ${pair}`);
    expect(found).toEqual([]);
  });
});

describe("backgroundPanelFor", () => {
  const panel = { sessionId: "a", expanded: true, dismissed: new Set(["x"]) };
  test("keeps the panel of the chat shown, and closes it on another chat in a chat pane", () => {
    expect(backgroundPanelFor(panel, "a", false)).toBe(panel);
    expect(backgroundPanelFor(panel, "b", false)).toBeUndefined();
    expect(backgroundPanelFor(undefined, "a", false)).toBeUndefined();
  });

  test("the Background tasks tab always shows the panel of the chat shown", () => {
    expect(backgroundPanelFor(undefined, "a", true)).toMatchObject({ sessionId: "a", expanded: false });
    expect(backgroundPanelFor(panel, "b", true)).toMatchObject({ sessionId: "b", expanded: false });
    expect(backgroundPanelFor(panel, "a", true)).toBe(panel);
    expect(backgroundPanelFor(undefined, undefined, true)).toBeUndefined();
  });

  test("one step reaches the answer, so a render-phase set happens at most once", () => {
    const cases = [undefined, panel, { ...panel, sessionId: undefined }];
    for (const start of cases)
      for (const sessionId of [undefined, "a", "b"])
        for (const own of [false, true]) {
          const once = backgroundPanelFor(start, sessionId, own);
          expect(backgroundPanelFor(once, sessionId, own)).toBe(once);
        }
  });
});
