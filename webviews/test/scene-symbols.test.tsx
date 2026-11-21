// Scene symbols in the React renderer draw what the native renderer draws (#40428 review F1): the
// catalog's icon for a symbol, a pack icon of that name, else the SF Symbol itself as the host's
// image (`__appsymbol/<name>.png`). Every symbol a bundled, sample or example app names resolves.
import { expect, test } from "bun:test";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import { renderToStaticMarkup } from "react-dom/server";
import { MISSING_ICON } from "../src/agent-session/acpmux/icons/iconPack";
import { SceneRenderer } from "../src/apps/scene/SceneRenderer";
import { sceneSymbolSource, symbolImageURL } from "../src/apps/scene/SceneSymbol";
import { SceneStore } from "../src/apps/scene/store";

const REPO = join(import.meta.dir, "../..");
const ROOTS = [
  "first-party-apps",
  "samples/apps",
  "examples",
  "skills/cmux-customization",
  "Packages/macOS/CmuxNext/Sources/CmuxNextApps/Resources/AppPlatform",
];
/** Names apps pass that are no SF Symbol, so neither renderer draws them. */
const NOT_SYMBOLS: Record<string, string> = {
  // CodeRouter's "Finish setting up" row accessory (surfaces.ts); the native row draws nothing either.
  chevron: "first-party-apps/coderouter/src/views/surfaces.ts",
};
const SWIFT_TEST = "Packages/macOS/CmuxNext/Tests/CmuxNextAgentPaneTests/AppSceneSymbolImagesTests.swift";
const resolveSymbol = (name: string) => symbolImageURL("/__appsymbol/", name);

function* sourceFiles(dir: string): Generator<string> {
  for (const entry of readdirSync(dir)) {
    if (entry === "node_modules" || entry.startsWith(".")) continue;
    const path = join(dir, entry);
    if (statSync(path).isDirectory()) yield* sourceFiles(path);
    else if (/\.(ts|tsx|js|mjs|json|md)$/.test(entry)) yield path;
  }
}

/** The expression from `start` to its end: a closing bracket at depth 0, or (unless `call`) a
 * comma, semicolon or newline at depth 0. */
function expression(text: string, start: number, call: boolean): string {
  let depth = 0;
  let quote = "";
  for (let i = start; i < text.length; i++) {
    const c = text[i]!;
    if (quote) {
      if (c === "\\") i++;
      else if (c === quote) quote = "";
    } else if (c === '"' || c === "'" || c === "`") quote = c;
    else if ("([{".includes(c)) depth++;
    else if (")]}".includes(c)) {
      if (depth === 0) return text.slice(start, i);
      depth--;
    } else if (depth === 0 && !call && ",;\n".includes(c)) return text.slice(start, i);
  }
  return text.slice(start);
}

/** Every symbol name an app's scene can carry: the values of `symbol`, `accessory`,
 * `systemImage` and `systemName` props, `Icon(...)` arguments, and what an app's own
 * `*symbol*` helpers and tables return, with compared values, keys and type arguments left out. */
function bundledSymbols(): Map<string, string> {
  const found = new Map<string, string>();
  const triggers: [RegExp, boolean][] = [
    [/\b(?:symbol|accessory|systemImage|systemName)\b["']?\s*:\s*/g, false],
    [/\bIcon\(/g, true],
    [/\b(?:const|let|function)\s+\w*(?:symbol|Symbol|SYMBOL)\w*\s*/g, false],
  ];
  for (const root of ROOTS) {
    for (const file of sourceFiles(join(REPO, root))) {
      const text = readFileSync(file, "utf8");
      for (const [pattern, call] of triggers) {
        for (const match of text.matchAll(pattern)) {
          const expr = expression(text, match.index + match[0].length, call);
          for (const literal of expr.matchAll(/["'`]([^"'`\n]*)["'`]/g)) {
            const name = literal[1]!;
            const before = expr.slice(0, literal.index);
            const after = expr.slice(literal.index + literal[0].length);
            if (/(?:[=!]==?|\bcase)\s*$/.test(before) || /^\s*[=!]==?/.test(after)) continue;
            if (/[{,]\s*$/.test(before) && /^\s*:/.test(after)) continue;
            // A type argument (`Pick<Item, "kind">`), not a comparison (`a < b ? ...`).
            if (/\w<[^<>]*$/.test(before)) continue;
            if (/^[a-z0-9]+(?:\.[a-z0-9]+)*$/.test(name) && /[a-z]/.test(name) && !found.has(name)) {
              found.set(name, relative(REPO, file));
            }
          }
        }
      }
    }
  }
  return found;
}

const symbols = bundledSymbols();

test("the scan finds the symbols the review named, from Caffeinate, Usage and Finder", () => {
  expect(symbols.size).toBeGreaterThan(100);
  for (const name of [
    "circle",
    "chevron.right",
    "chevron.down",
    "cup.and.saucer",
    "checkmark.circle.fill",
    "play.fill",
  ]) {
    expect(symbols.has(name)).toBe(true);
  }
});

test("every symbol a bundled app names resolves to a pack icon or the host's drawing, never icon.missing", () => {
  const missing: string[] = [];
  for (const [name, file] of symbols) {
    if (Object.hasOwn(NOT_SYMBOLS, name)) continue;
    const source = sceneSymbolSource(name, undefined, resolveSymbol);
    if ("icon" in source && source.icon === MISSING_ICON) missing.push(`${name} (${file})`);
  }
  expect(missing).toEqual([]);
});

test("a symbol the catalog stands for draws the native renderer's pack icon, with or without a host", () => {
  for (const host of [undefined, resolveSymbol]) {
    expect(sceneSymbolSource("circle", undefined, host)).toEqual({ icon: "list.bullet.item" });
    expect(sceneSymbolSource("chevron.right", undefined, host)).toEqual({ icon: "disclosure.collapsed" });
    expect(sceneSymbolSource("chevron.down", undefined, host)).toEqual({ icon: "disclosure.expanded" });
  }
  // A pack icon name passes through.
  expect(sceneSymbolSource("folder", undefined, resolveSymbol)).toEqual({ icon: "folder" });
});

test("a symbol the pack has no icon for uses the host's general SF Symbol drawing", () => {
  expect(sceneSymbolSource("cup.and.saucer", undefined, resolveSymbol)).toEqual({
    image: "/__appsymbol/cup.and.saucer.png",
  });
  expect(sceneSymbolSource("not.a.real.sf.symbol", undefined, resolveSymbol)).toEqual({
    image: "/__appsymbol/not.a.real.sf.symbol.png",
  });
  // No host (Home widgets, the gallery): the nearest pack icon, else the neutral missing glyph.
  expect(sceneSymbolSource("cup.and.saucer")).toEqual({ icon: MISSING_ICON });
  expect(sceneSymbolSource("arrow.triangle.pull")).toEqual({ icon: "git.pullrequest" });
  // Only symbol names become URLs.
  for (const bad of ["../secret", "Cup", "a..b", ".a", "a b", "a/b", "x".repeat(129)]) {
    expect(resolveSymbol(bad)).toBeUndefined();
    expect(sceneSymbolSource(bad, undefined, resolveSymbol)).toEqual({ icon: MISSING_ICON });
  }
  expect(symbolImageURL(undefined, "cup.and.saucer")).toBeUndefined();
  expect(symbolImageURL("/__appsymbol", "cup.and.saucer")).toBeUndefined();
});

test("a scene draws an SF-only symbol as a mask of the host's image in the node's color", () => {
  const store = new SceneStore();
  store.apply([
    { op: "create", id: "root", type: "VStack", props: {} },
    { op: "create", id: "cup", type: "Icon", props: { symbol: "cup.and.saucer", color: "accent" } },
    { op: "create", id: "dot", type: "Icon", props: { symbol: "circle" } },
    { op: "children", id: "root", children: ["cup", "dot"] },
    { op: "root", id: "root" },
  ]);
  const html = renderToStaticMarkup(<SceneRenderer store={store} dispatch={() => {}} resolveSymbol={resolveSymbol} />);
  expect(html).toContain('data-symbol="cup.and.saucer"');
  expect(html).toContain("url(&quot;/__appsymbol/cup.and.saucer.png&quot;)");
  expect(html).toContain('data-icon="list.bullet.item"');
  expect(html).not.toContain(`data-icon="${MISSING_ICON}"`);
  // Without a host the same scene keeps the missing glyph and asks for no image.
  const bare = renderToStaticMarkup(<SceneRenderer store={store} dispatch={() => {}} />);
  expect(bare).not.toContain("__appsymbol");
});

test("the Swift test draws every symbol the scan finds", () => {
  const swift = readFileSync(join(REPO, SWIFT_TEST), "utf8");
  const block = /static let bundledSymbols: \[String\] = \[([^\]]*)\]/.exec(swift)?.[1] ?? "";
  const listed = [...block.matchAll(/"([^"]+)"/g)].map((match) => match[1]!);
  const scanned = [...symbols.keys()].filter((name) => !Object.hasOwn(NOT_SYMBOLS, name)).sort();
  expect(listed).toEqual(scanned);
});
