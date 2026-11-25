/**
 * Looks on public surfaces only (docs/cmux-next/look-addons.md; Leo, 2026-11-18: "make sure stuff is
 * faithful + doesn't shift + we're able to get the stuff good using sdks and apis so ppl can/could
 * have recreated and customized stuff to their liking").
 *
 * The chat's stylesheet contract, schemas/agent-pane/style-tokens.json (cmux.agentPane.style/1):
 *   undeclared    a token is not declared on a root selector (`:root`, `html`) in its owner file, so a
 *                 person's `:root { ... }` could not set it.
 *   scoped        a token is also declared under another selector outside `alsoScopedIn`, so a look's
 *                 value would silently stop at that element.
 *   unused        no stylesheet reads the token (`var(<token>`): setting it would do nothing.
 *   host-pushed   the token is one the host sets inline on the root (shared/theme.ts), which no
 *                 stylesheet can beat: it belongs to the theme file's colors, not this contract.
 * Every look add-on (examples/looks/looks.json, `addon`), its agent-pane/theme.css:
 *   selector      a rule on anything but `:root`: class names are not public, and renames break it.
 *   private-token a declaration of anything but a contract token (a property, or an internal variable).
 *   remote        `@import` or `url(`: a look draws nothing from outside.
 *   literal-color a color token set to a literal color (`#hex`, `rgb()`, `oklch()`, a named color) instead
 *                 of one made from the theme's own (`var(--agent-text)`, `color-mix(in srgb, var(--agent-accent)
 *                 12%, transparent)`): a literal is right for one appearance only, so the look breaks over
 *                 the other (Studio's grey bubble under black text in light, 2.9:1; Paper's beige under
 *                 white text in dark, 1.4:1, cmux#46049). test/browser/look-addons.test.ts holds the
 *                 drawn text of every look to WCAG contrast in both appearances.
 * Built-in looks (COMPOSER_LOOKS in composerLook.ts, TRANSCRIPT_LOOKS in conversation/transcriptLook.ts
 * once it exists):
 *   no-twin       a built-in look id has no entry in looks.json: nobody proved an outsider can make it.
 *
 *   bun scripts/check-look-addons.ts          (from webviews/; exits 1 with a line per problem)
 */
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const webviews = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const repo = path.join(webviews, "..");
export const CONTRACT_PATH = path.join(repo, "schemas/agent-pane/style-tokens.json");
export const LOOKS_PATH = path.join(repo, "examples/looks/looks.json");

export type Token = { name: string; kind: string; owner: string; alsoScopedIn?: string[]; about: string };
export type Contract = { interface: string; selectors: string[]; tokens: Token[] };
export type Look = { id: string; addon: string | null; builtIn: unknown; pending?: string };
export type Problem = { kind: string; where: string; message: string };

/** One custom property declaration: its name, the selector chain above it (outermost first). */
export type Declaration = { name: string; selectors: string[] };

/** Every `--name:` declaration in `css`, with its enclosing selectors. Comments are stripped first. */
export function declarations(css: string): Declaration[] {
  const text = css.replace(/\/\*[\s\S]*?\*\//g, "");
  const found: Declaration[] = [];
  const stack: string[] = [];
  let buffer = "";
  const flush = () => {
    const match = /^\s*(--[A-Za-z0-9_-]+)\s*:/.exec(buffer);
    if (match) found.push({ name: match[1]!, selectors: [...stack] });
    buffer = "";
  };
  for (const char of text) {
    if (char === "{") {
      stack.push(buffer.trim().replace(/\s+/g, " "));
      buffer = "";
    } else if (char === "}") {
      flush();
      stack.pop();
    } else if (char === ";") flush();
    else buffer += char;
  }
  return found;
}

/** Whether every selector in a rule's chain is a root selector or an at-rule (`@media`, `@supports`). */
export function rootLevel(selectors: string[]): boolean {
  return (
    selectors.length > 0 &&
    selectors.every(
      (selector) =>
        selector.startsWith("@") ||
        selector
          .split(",")
          .map((part) => part.trim())
          .every((part) => /^(?::root|html)(?:\[[^\]]*\]|:not\([^)]*\)|:where\([^)]*\))*$/.test(part)),
    )
  );
}

/** The variables shared/theme.ts sets inline on the root: they win over any stylesheet. */
export function hostPushed(themeSource: string): Set<string> {
  const pushed = new Set<string>();
  for (const match of themeSource.matchAll(/"(--[a-z0-9-]+)"/g)) pushed.add(match[1]!);
  for (const match of themeSource.matchAll(/`(--[a-z0-9-]+)-\$\{/g)) pushed.add(`${match[1]}-*`);
  return pushed;
}

function cssFiles(dir: string, out: string[] = []): string[] {
  for (const name of readdirSync(dir)) {
    const file = path.join(dir, name);
    if (statSync(file).isDirectory()) {
      if (name !== "node_modules" && name !== "generated") cssFiles(file, out);
    } else if (name.endsWith(".css") && !name.endsWith(".gallery.css")) out.push(file);
  }
  return out;
}

/** The contract against the shipped stylesheets (`sheets`: repo-relative path to text) and the host. */
export function checkContract(contract: Contract, sheets: Map<string, string>, pushed: Set<string>): Problem[] {
  const problems: Problem[] = [];
  const decls = new Map<string, Array<Declaration & { file: string }>>();
  const reads = new Set<string>();
  /** `file token`: the file reads the token with a fallback (`var(--token, ...)`). */
  const fallbacks = new Set<string>();
  for (const [file, css] of sheets) {
    for (const decl of declarations(css)) {
      const list = decls.get(decl.name) ?? [];
      list.push({ ...decl, file });
      decls.set(decl.name, list);
    }
    for (const match of css.matchAll(/var\(\s*(--[A-Za-z0-9_-]+)\s*(,)?/g)) {
      reads.add(match[1]!);
      if (match[2]) fallbacks.add(`${file} ${match[1]}`);
    }
  }
  for (const token of contract.tokens) {
    const where = `${CONTRACT_PATH.slice(repo.length + 1)} ${token.name}`;
    if (pushed.has(token.name) || [...pushed].some((p) => p.endsWith("-*") && token.name.startsWith(p.slice(0, -1))))
      problems.push({
        kind: "host-pushed",
        where,
        message: "the host sets this inline (shared/theme.ts); set it with the theme file's colors",
      });
    const mine = decls.get(token.name) ?? [];
    // Declared on the root in its owner, or (a token with no value of its own) declared nowhere and
    // read there with today's value as the fallback: either way a person's `:root` value wins.
    const rootDeclared = mine.some((decl) => decl.file === token.owner && rootLevel(decl.selectors));
    const fallbackOnly = mine.length === 0 && fallbacks.has(`${token.owner} ${token.name}`);
    if (!rootDeclared && !fallbackOnly)
      problems.push({
        kind: "undeclared",
        where,
        message: `neither declared on :root nor read with a fallback in ${token.owner}`,
      });
    for (const decl of mine) {
      if (rootLevel(decl.selectors) || (token.alsoScopedIn ?? []).includes(decl.file)) continue;
      problems.push({
        kind: "scoped",
        where: `${decl.file} ${decl.selectors.join(" >> ")}`,
        message: `${token.name} is declared below the root here, so a look's value stops at it; declare it on :root or list the file in alsoScopedIn`,
      });
    }
    if (!reads.has(token.name)) problems.push({ kind: "unused", where, message: "no stylesheet reads it" });
  }
  return problems;
}

/** Words a color made from the theme's own may hold besides `var(--name)`: the color-mix grammar. */
const MIX_WORDS = new Set([
  "color-mix",
  // light-dark(A, B): the page's color-scheme (theme.ts) picks A or B, so it follows the appearance.
  "light-dark",
  "in",
  "srgb",
  "srgb-linear",
  "oklab",
  "oklch",
  "lab",
  "lch",
  "hsl",
  "hwb",
  "display-p3",
  "xyz",
  "shorter",
  "longer",
  "increasing",
  "decreasing",
  "hue",
  "transparent",
  "currentcolor",
]);

/** Whether a color value is made only from other variables (the theme's, the chat's), so it follows the
 * appearance: `var()`, `color-mix()` over them, `transparent`, `currentColor` and percentages. */
export function themeDerived(value: string): boolean {
  // `oklch(`, `rgb(` and the rest as functions are literals; as color-mix's space (`in oklch`) they are words.
  if (/#[0-9a-f]{3,8}\b/i.test(value) || /\b(?:rgba?|hsla?|hwb|lab|lch|oklab|oklch|color)\s*\(/i.test(value))
    return false;
  const rest = value.replace(/var\(\s*--[A-Za-z0-9_-]+/g, " ").toLowerCase();
  return (rest.match(/[a-z][a-z0-9-]*/g) ?? []).every((word) => MIX_WORDS.has(word));
}

/** A look's agent-pane/theme.css against the contract. */
export function checkAddonCss(file: string, css: string, contract: Contract): Problem[] {
  const problems: Problem[] = [];
  const allowed = new Set(contract.tokens.map((token) => token.name));
  const colors = new Set(contract.tokens.filter((token) => token.kind === "color").map((token) => token.name));
  const text = css.replace(/\/\*[\s\S]*?\*\//g, "");
  if (/@import\b|url\(/i.test(text))
    problems.push({ kind: "remote", where: file, message: "a look loads nothing: no @import or url()" });
  const stack: string[] = [];
  let buffer = "";
  const flush = () => {
    const line = buffer.trim();
    buffer = "";
    if (!line) return;
    const name = /^([A-Za-z0-9_-]+)\s*:/.exec(line)?.[1];
    if (!name || !allowed.has(name))
      problems.push({
        kind: "private-token",
        where: `${file} ${stack.join(" >> ")}`,
        message: `${name ?? line} is not a ${contract.interface} token (schemas/agent-pane/style-tokens.json)`,
      });
    else if (colors.has(name) && !themeDerived(line.slice(line.indexOf(":") + 1)))
      problems.push({
        kind: "literal-color",
        where: `${file} ${stack.join(" >> ")} ${name}`,
        message:
          "a look's colors come from the theme's (var(--agent-text), color-mix(in srgb, var(--agent-accent) 12%, transparent)), so it reads in light and dark; set literal colors in the theme file",
      });
  };
  for (const char of text) {
    if (char === "{") {
      const selector = buffer.trim().replace(/\s+/g, " ");
      buffer = "";
      if (!selector.startsWith("@") && !contract.selectors.includes(selector))
        problems.push({
          kind: "selector",
          where: `${file} ${selector}`,
          message: `a look styles ${contract.selectors.join(", ")} only; class names are not public`,
        });
      stack.push(selector);
    } else if (char === "}") {
      flush();
      stack.pop();
    } else if (char === ";") flush();
    else buffer += char;
  }
  return problems;
}

/** Built-in look ids: the composer's, and the transcript's once that file lands. */
export function builtInLooks(): string[] {
  const ids: string[] = [];
  const sources: Array<[string, RegExp]> = [
    ["src/agent-session/acpmux/composerLook.ts", /COMPOSER_LOOKS\s*=\s*\[([^\]]*)\]/],
    ["src/agent-session/acpmux/conversation/transcriptLook.ts", /TRANSCRIPT_LOOKS\s*=\s*\[([^\]]*)\]/],
  ];
  for (const [file, pattern] of sources) {
    const full = path.join(webviews, file);
    if (!existsSync(full)) continue;
    const list = pattern.exec(readFileSync(full, "utf8"))?.[1] ?? "";
    for (const match of list.matchAll(/"([a-z0-9-]+)"/g)) ids.push(match[1]!);
  }
  return [...new Set(ids)];
}

export function checkLooks(looks: Look[], builtIn: string[], contract: Contract): Problem[] {
  const problems: Problem[] = [];
  const listed = new Set(looks.map((look) => look.id));
  for (const id of builtIn)
    if (!listed.has(id))
      problems.push({
        kind: "no-twin",
        where: LOOKS_PATH.slice(repo.length + 1),
        message: `the built-in look "${id}" has no entry: add its add-on twin, or a pending reason`,
      });
  for (const look of looks) {
    if (!look.addon) {
      if (!look.pending) problems.push({ kind: "no-twin", where: look.id, message: "no add-on and no pending reason" });
      continue;
    }
    const css = path.join(repo, "examples/looks", look.addon, "agent-pane/theme.css");
    if (!existsSync(css)) continue;
    problems.push(...checkAddonCss(path.relative(repo, css), readFileSync(css, "utf8"), contract));
  }
  return problems;
}

export function run(): Problem[] {
  const contract = JSON.parse(readFileSync(CONTRACT_PATH, "utf8")) as Contract;
  const sheets = new Map<string, string>();
  for (const file of cssFiles(path.join(webviews, "src")))
    sheets.set(path.relative(repo, file).split(path.sep).join("/"), readFileSync(file, "utf8"));
  const pushed = hostPushed(readFileSync(path.join(webviews, "src/agent-session/shared/theme.ts"), "utf8"));
  const looks = (JSON.parse(readFileSync(LOOKS_PATH, "utf8")) as { looks: Look[] }).looks;
  return [...checkContract(contract, sheets, pushed), ...checkLooks(looks, builtInLooks(), contract)];
}

if (import.meta.main) {
  const problems = run();
  for (const problem of problems)
    console.error(`check-look-addons: ${problem.kind}: ${problem.where}: ${problem.message}`);
  if (problems.length) process.exit(1);
  console.log("check-look-addons: every look uses public surfaces only, and every contract token works from :root");
}
