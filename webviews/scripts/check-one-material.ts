// One material per surface (design/glass-system.md, "One material per surface"). Leo, 2026-11-21: "our
// shitty multi layer glass + web view. we need to properly do that once and for all.", and on the
// prompt rail's hover preview drawn as an opaque box: "shietttt this web thing got disconnected from its
// glass... where is our proper glass redesign?". Every floating web surface draws exactly one material:
// the App's host glass (data-host-glass, ui/glass/hostGlass.ts) with the page's own fill, blur, rim and
// shadow cleared (glass.css HOST GLASS), or the page's one CSS glass (.ui-glass and its level tokens).
// Never both (a double tint), never neither (an opaque or bare box). This check fails:
//
//  a. backdrop  a CSS rule under webviews/src (not tests, galleries, prototypes) that declares a
//               backdrop-filter outside the glass painter: only .ui-glass paints one (glass.css, or a
//               .ui-glass rule whose value is var(--glass-backdrop)). A blur that is not a surface's
//               material (a scroll edge's masked fade, a scrim, the diff header's glass) says why on its
//               rule: `/* one-material-allow: <reason> */` inside the rule or on the line before its
//               selector. The allowed count is pinned (ALLOWED_MAX): it can only shrink.
//  b. material  such a rule also paints a translucent fill (color-mix with transparent, an alpha, a
//               --*tint* token): a private glass recipe beside .ui-glass, the prompt rail card's bug.
//  c. surface   a component renders a floating surface class (FLOATING) with no data-host-glass mark
//               and no `data-page-glass="<reason>"` of its own, in the agent pane's code (ui/,
//               agent-session/), where the App draws host glass. A marked surface must carry .ui-glass:
//               it is the page's material when the App does not draw (data-host-glass-drawn="0").
//               Files on the backlog (PENDING, and surface-materials.json web_floating_pending) pass
//               and fail as stale once clean.
//  d. host      glass.css's HOST GLASS rules (one per engine gate) do not both clear a drawn surface's
//               fill to transparent, its backdrop-filter to none, its rim and its border; or a stylesheet
//               gives --host-glass-fill a fill other than transparent.
//
// test/one-material.test.ts runs it; `bun scripts/check-one-material.ts` runs it alone. The browser
// half (computed styles of each floating primitive drawn and not drawn) is
// test/one-material-browser.test.ts.
import { readdirSync, readFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
export const SRC = join(HERE, "../src");
const MANIFEST = join(HERE, "../../schemas/surface-materials/surface-materials.json");

/** How many backdrop-filter rules may carry `one-material-allow`. Lower it when one goes; never raise it. */
export const ALLOWED_MAX = 26;

const ALLOW = /one-material-allow:\s*\S/;
const SKIP_FILE = /\.(test|gallery|dom\.test)\.[cm]?[jt]sx?$|\.gallery\.css$/;
const SKIP_DIR = new Set(["node_modules", "prototypes", "prototype", "gallery"]);
const GLASS_CSS = "ui/glass/glass.css";
const NO_FILTER = /^(none|initial|inherit|unset|revert|revert-layer)$/i;

/** The floating surface classes: each is drawn on one material. */
export const FLOATING = [
  "ui-popup",
  "ui-tooltip",
  "ui-notice",
  "ui-dialog",
  "acpmux-composer-box",
  "nt-composer-surface",
  "acpmux-minimap__card",
] as const;
const SURFACE_SCOPES = ["ui/", "agent-session/"];

/** Agent-pane files whose floating surfaces are not yet on one decided material, with why. Shrink only. */
export const PENDING: Record<string, string> = {
  "agent-session/acpmux/SlashMenu.tsx":
    "the slash menu's Listbox shell (shellClassName) takes no host-glass mark yet: page glass",
  "agent-session/acpmux/MentionMenu.tsx":
    "the mention menu's Listbox shell (shellClassName) takes no host-glass mark yet: page glass",
  "agent-session/acpmux/HelpSheet.tsx":
    "drawn in the slash list's place and material (SlashMenu, above); they move to host glass together: page glass",
};
/** Files that render a floating class but no live surface. */
const EXEMPT: Record<string, string> = {
  "agent-session/acpmux/ManagedBannerDesigns.tsx":
    "design mocks the gallery alone renders (ManagedBannerDesigns.gallery.tsx)",
};

function* walk(dir: string, ext: RegExp): Generator<string> {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const full = join(dir, entry.name);
    if (entry.isDirectory()) {
      if (!SKIP_DIR.has(entry.name)) yield* walk(full, ext);
    } else if (ext.test(entry.name) && !SKIP_FILE.test(entry.name)) yield full;
  }
}

// ---------------------------------------------------------------------------------------------------
// CSS

export interface Rule {
  /** Line of the selector's first character (1-based). */
  line: number;
  selector: string;
  /** Enclosing at-rules and parent selectors. */
  context: string[];
  decls: { prop: string; value: string; line: number }[];
  /** A `one-material-allow` comment inside the rule or on the line before its selector. */
  allowed: boolean;
}

/** Every rule of `css` with its declarations; comments read for the allowance, then dropped. */
export function parseCss(css: string): Rule[] {
  const text = css.replace(/design-scale:begin[\s\S]*?design-scale:end/g, (block) => block.replace(/[^\n]/g, " "));
  const lines = css.split("\n");
  const rules: Rule[] = [];
  const stack: Rule[] = [];
  let buf = "";
  let bufStart = -1;
  let line = 1;
  let i = 0;
  // An allow comment before a selector (or a declaration) belongs to the rule that opens next.
  let pendingAllow = false;
  const flush = () => {
    pendingAllow = false;
    const decl = buf.trim();
    const at = bufStart;
    buf = "";
    bufStart = -1;
    const rule = stack.at(-1);
    const colon = decl.indexOf(":");
    if (!rule || colon <= 0) return;
    rule.decls.push({
      prop: decl.slice(0, colon).trim().toLowerCase(),
      value: decl
        .slice(colon + 1)
        .trim()
        .replace(/\s*!important$/, "")
        .replace(/\s+/g, " "),
      line: at,
    });
  };
  while (i < text.length) {
    const ch = text[i]!;
    if (ch === "/" && text[i + 1] === "*") {
      const end = text.indexOf("*/", i + 2);
      const comment = text.slice(i, end < 0 ? text.length : end + 2);
      if (ALLOW.test(comment)) {
        // Inside a rule it allows that rule; before a selector, the rule it opens.
        if (stack.length > 0) stack.at(-1)!.allowed = true;
        if (buf.trim() === "") pendingAllow = true;
      }
      line += comment.split("\n").length - 1;
      i += comment.length;
      continue;
    }
    if (ch === '"' || ch === "'") {
      const end = text.indexOf(ch, i + 1);
      buf += text.slice(i, end < 0 ? text.length : end + 1);
      i = end < 0 ? text.length : end + 1;
      continue;
    }
    if (ch === "\n") line++;
    else if (bufStart < 0 && !/\s/.test(ch)) bufStart = line;
    if (ch === "{") {
      const selector = buf.trim().replace(/\s+/g, " ");
      const start = bufStart < 0 ? line : bufStart;
      buf = "";
      bufStart = -1;
      const before = lines[start - 2] ?? "";
      const own = lines[start - 1] ?? "";
      rules.push({
        line: start,
        selector,
        context: stack.map((rule) => rule.selector),
        decls: [],
        allowed: pendingAllow || ALLOW.test(before) || ALLOW.test(own),
      });
      pendingAllow = false;
      stack.push(rules.at(-1)!);
    } else if (ch === "}") {
      flush();
      stack.pop();
    } else if (ch === ";") {
      flush();
    } else buf += ch;
    i++;
  }
  return rules;
}

const BACKDROP = new Set(["backdrop-filter", "-webkit-backdrop-filter"]);
const FILL = new Set(["background", "background-color"]);
/** A fill that lets what is under it through: a mix toward transparent, an alpha, or a tint token. */
export function translucent(value: string): boolean {
  if (/\btransparent\b/.test(value) && /color-mix|gradient/.test(value)) return true;
  if (/rgba\(|hsla\(|\/\s*(0?\.\d+|\d{1,2}(\.\d+)?%)\s*\)/.test(value)) return true;
  return /var\(--[\w-]*(tint|glass|veil|frost)[\w-]*/.test(value);
}

/** Whether the rule is .ui-glass's own painter: glass.css's glass, or a .ui-glass rule reading its token. */
function painter(file: string, rule: Rule, value: string): boolean {
  const glassSelector =
    /\.ui-glass\b/.test(rule.selector) || rule.context.some((parent) => /\.ui-glass\b/.test(parent));
  if (file === GLASS_CSS) return glassSelector || /\[data-host-glass\]/.test(rule.selector);
  return glassSelector && /^var\(--glass-backdrop\)$/.test(value);
}

export interface CssFindings {
  /** `file:line: [rule] selector { ... }` for each rule that fails. */
  errors: string[];
  /** Each allowed rule, `file:line: selector`. */
  allowed: string[];
}

/** Rules a and b for one stylesheet. */
export function backdropRules(css: string, file: string): CssFindings {
  const errors: string[] = [];
  const allowed: string[] = [];
  for (const rule of parseCss(css)) {
    const filters = rule.decls.filter((decl) => BACKDROP.has(decl.prop) && !NO_FILTER.test(decl.value));
    if (filters.length === 0) continue;
    if (filters.every((decl) => painter(file, rule, decl.value))) continue;
    if (rule.allowed) {
      allowed.push(`${file}:${rule.line}: ${rule.selector}`);
      continue;
    }
    const fill = rule.decls.find((decl) => FILL.has(decl.prop) && translucent(decl.value));
    const where = `${file}:${rule.line}: ${rule.selector}`;
    if (fill)
      errors.push(
        `${where} [material] paints its own glass (${fill.prop}: ${fill.value}; backdrop-filter: ${filters[0]!.value}) ` +
          "outside .ui-glass: put the surface on .ui-glass and its level tokens (--glass-tint, --glass-backdrop)",
      );
    else
      errors.push(
        `${where} [backdrop] declares backdrop-filter: ${filters[0]!.value} outside the .ui-glass painter: ` +
          "use .ui-glass (--glass-backdrop), or say why it is no surface's material: /* one-material-allow: <reason> */",
      );
  }
  return { errors, allowed };
}

/** Rule d over glass.css: each HOST GLASS rule clears a drawn surface's whole material. */
export function hostGlassRule(css: string): string[] {
  const errors: string[] = [];
  const drawn = parseCss(css).filter(
    (rule) => /\[data-host-glass-drawn="1"\]/.test(rule.selector) && /\[data-host-glass\]/.test(rule.selector),
  );
  if (drawn.length < 2)
    errors.push(
      `${GLASS_CSS}: [host] expected the HOST GLASS rule for Chromium and for both engines, found ${drawn.length}`,
    );
  const conditions = new Set<string>();
  for (const rule of drawn) {
    const value = (prop: string) => rule.decls.find((decl) => decl.prop === prop)?.value;
    const where = `${GLASS_CSS}:${rule.line}: [host]`;
    const fill = value("background") ?? value("background-color");
    if (!fill || !/^(transparent|var\(--host-glass-fill, ?transparent\))$/.test(fill))
      errors.push(
        `${where} a drawn surface keeps a fill of its own (${fill ?? "none set"}): the App's glass is its one material`,
      );
    for (const prop of BACKDROP)
      if (value(prop) !== "none")
        errors.push(
          `${where} a drawn surface keeps ${prop}: ${value(prop) ?? "unset"}; only the cover's in-place blur may stay`,
        );
    const shadow = value("box-shadow");
    if (!shadow || !/^(none|var\(--host-glass-edge, ?none\))$/.test(shadow))
      errors.push(`${where} a drawn surface keeps a rim or shadow of its own (${shadow ?? "unset"})`);
    if (value("border-color") !== "transparent") errors.push(`${where} a drawn surface keeps its border's color`);
    // The decision: the same states for both engine gates (drawn, not keeping the underlay, cover only
    // where the page blurs in place). The class list and the root's engine gate may differ.
    conditions.add(
      rule.selector
        .replace(/^:root\S*\s+/, "")
        .replace(/:is\(\.ui-glass, \.ui-tooltip\)$|\.ui-glass\.ui-glass$/, "")
        .replace(/\s+/g, " "),
    );
    if (!/\[data-glass-keeps-underlay\]/.test(rule.selector) || !/\[data-glass-over\]/.test(rule.selector))
      errors.push(
        `${where} the rule must leave the page's glass on a surface over the composer and on a cover with nothing blurred`,
      );
  }
  if (conditions.size > 1)
    errors.push(`${GLASS_CSS}: [host] the HOST GLASS rules decide differently: ${[...conditions].join(" | ")}`);
  return errors;
}

/** Rule d's other half: no stylesheet lays a fill of its own on the App's glass. */
export function hostFills(css: string, file: string): string[] {
  const errors: string[] = [];
  for (const rule of parseCss(css))
    for (const decl of rule.decls)
      if (decl.prop === "--host-glass-fill" && decl.value !== "transparent")
        errors.push(
          `${file}:${decl.line}: [host] --host-glass-fill: ${decl.value} lays a second tint on the App's glass`,
        );
  return errors;
}

// ---------------------------------------------------------------------------------------------------
// TSX (rule c)

/** Each JSX opening tag: its offset and text (to its closing `>` outside braces and strings). */
export function* openingTags(text: string): Generator<{ offset: number; tag: string }> {
  const start = /<[A-Za-z][\w.]*/g;
  for (let match = start.exec(text); match; match = start.exec(text)) {
    let depth = 0;
    let quote = "";
    let index = match.index + match[0].length;
    for (; index < text.length; index++) {
      const char = text[index]!;
      if (quote) {
        if (char === "\\") index++;
        else if (char === quote) quote = "";
        continue;
      }
      if (text.startsWith("//", index)) {
        const end = text.indexOf("\n", index);
        index = end < 0 ? text.length : end;
        continue;
      }
      if (text.startsWith("/*", index)) {
        const end = text.indexOf("*/", index + 2);
        index = end < 0 ? text.length : end + 1;
        continue;
      }
      if (char === '"' || char === "'" || char === "`") quote = char;
      else if (char === "{") depth++;
      else if (char === "}") depth--;
      else if (depth === 0 && char === ">") break;
      else if (depth === 0 && char === "<") break;
    }
    if (text[index] === ">") yield { offset: match.index, tag: text.slice(match.index, index + 1) };
  }
}

/** The classes a tag's `className` (or `*ClassName`) attributes name in their string literals. */
export function tagClasses(tag: string): string[] {
  const out: string[] = [];
  const attribute = /\b(\w*[cC]lassName)\s*=\s*/g;
  for (let match = attribute.exec(tag); match; match = attribute.exec(tag)) {
    let index = match.index + match[0].length;
    const open = tag[index];
    let value = "";
    if (open === '"' || open === "'") value = tag.slice(index, tag.indexOf(open, index + 1) + 1);
    else if (open === "{") {
      let depth = 0;
      for (; index < tag.length; index++) {
        if (tag[index] === "{") depth++;
        else if (tag[index] === "}" && --depth === 0) break;
      }
      value = tag.slice(match.index + match[0].length, index + 1);
    }
    for (const literal of value.matchAll(/"([^"]*)"|'([^']*)'|`([^`]*)`/g))
      out.push(...(literal[1] ?? literal[2] ?? literal[3] ?? "").replace(/\$\{[^}]*\}/g, " ").split(/\s+/));
  }
  return out.filter(Boolean);
}

const HOST_MARK = /(?:^|[\s{,])["']?data-host-glass["']?\s*[=:]/;
const PAGE_MARK = /\bdata-page-glass\s*=\s*["'{][^"'}]*\S/;

/** Rule c for one component: `line: message` for each floating surface on no decided material. */
export function unmarkedSurfaces(text: string): { line: number; message: string }[] {
  const out: { line: number; message: string }[] = [];
  // A class list held in a const of the same file (`const popupClassName = cx("ui-popup ui-glass", ...)`).
  const held = new Map<string, string[]>();
  for (const match of text.matchAll(/\bconst\s+(\w+)\s*=\s*(cx\([^;]*?\)|"[^"]*"|`[^`]*`);/g))
    held.set(
      match[1]!,
      [...match[2]!.matchAll(/"([^"]*)"|`([^`]*)`/g)].flatMap((m) => (m[1] ?? m[2] ?? "").split(/\s+/)),
    );
  for (const { offset, tag } of openingTags(text)) {
    // A surface that opts out of the App's glass (ui/Popover.tsx hostGlass={false}) says why.
    if (/\bhostGlass=\{false\}/.test(tag) && !PAGE_MARK.test(tag)) {
      out.push({
        line: text.slice(0, offset).split("\n").length,
        message: 'hostGlass={false} with no data-page-glass="<reason>": say why it keeps the page\'s glass',
      });
      continue;
    }
    const classes = tagClasses(tag);
    for (const [name, list] of held)
      if (new RegExp(`[cC]lassName\\s*=\\s*\\{[^}]*\\b${name}\\b`).test(tag)) classes.push(...list);
    const floating = FLOATING.filter((name) => classes.includes(name));
    if (floating.length === 0) continue;
    const line = text.slice(0, offset).split("\n").length;
    // ui/Popover.tsx marks its popup for the App's popover glass and wears .ui-glass itself unless
    // hostGlass={false} (handled above): a class passed to it is on a decided surface.
    if (/^<Popover\b/.test(tag)) continue;
    const host = HOST_MARK.test(tag) && !/\bhostGlass=\{false\}/.test(tag);
    if (host && !classes.includes("ui-glass") && !/ui-glass/.test(tag))
      out.push({
        line,
        message: `a .${floating[0]} marked for the App's glass without .ui-glass: when the App does not draw it, it has no material`,
      });
    else if (!host && !PAGE_MARK.test(tag))
      out.push({
        line,
        message:
          `a .${floating[0]} with no data-host-glass="menu|popover|chip" and no data-page-glass="<reason>": ` +
          "decide its one material (ui/glass/hostGlass.ts)",
      });
  }
  return out;
}

function pendingFiles(): Record<string, string> {
  let manifest: { web_floating_pending?: Record<string, string> } = {};
  try {
    manifest = JSON.parse(readFileSync(MANIFEST, "utf8"));
  } catch {
    // No manifest (a fixture root): only this script's backlog.
  }
  return { ...manifest.web_floating_pending, ...PENDING };
}

// ---------------------------------------------------------------------------------------------------

export interface Report {
  errors: string[];
  allowed: string[];
}

/** Every finding under `root` (webviews/src by default). */
export function checkOneMaterial(root = SRC, options: { pin?: number; pending?: Record<string, string> } = {}): Report {
  const errors: string[] = [];
  const allowed: string[] = [];
  for (const full of walk(root, /\.css$/)) {
    const file = relative(root, full);
    const css = readFileSync(full, "utf8");
    const found = backdropRules(css, file);
    errors.push(...found.errors, ...hostFills(css, file));
    allowed.push(...found.allowed);
    if (file === GLASS_CSS) errors.push(...hostGlassRule(css));
  }
  // A backdrop filter a script writes into a stylesheet string (the diff viewer's header glass).
  for (const full of walk(root, /\.tsx?$/)) {
    const file = relative(root, full);
    const lines = readFileSync(full, "utf8").split("\n");
    lines.forEach((text, index) => {
      const write = text.match(/(?:-webkit-)?backdrop-filter\s*:\s*([^;"'`]+)|backdropFilter\s*[:=]\s*([^,;}\n]+)/);
      if (!write || /^\s*(\/\/|\*)/.test(text)) return;
      const value = (write[1] ?? write[2] ?? "").trim().replace(/^["'`]|["'`]$/g, "");
      if (NO_FILTER.test(value) || /^none\b/.test(value) || /^"?none"?$/.test(value)) return;
      if (ALLOW.test(text) || ALLOW.test(lines[index - 1] ?? "") || ALLOW.test(lines[index - 2] ?? "")) {
        allowed.push(`${file}:${index + 1}: ${text.trim()}`);
        return;
      }
      errors.push(
        `${file}:${index + 1}: [backdrop] a script writes backdrop-filter: ${value} outside the .ui-glass painter: ` +
          "/* one-material-allow: <reason> */",
      );
    });
  }
  const pending = options.pending ?? pendingFiles();
  const unclean = new Set<string>();
  for (const full of walk(root, /\.tsx$/)) {
    const file = relative(root, full);
    if (!SURFACE_SCOPES.some((scope) => file.startsWith(scope)) || EXEMPT[file]) continue;
    const found = unmarkedSurfaces(readFileSync(full, "utf8"));
    if (found.length === 0) continue;
    unclean.add(file);
    if (pending[file]) continue;
    for (const { line, message } of found) errors.push(`${file}:${line}: [surface] ${message}`);
  }
  for (const file of Object.keys(PENDING))
    if (!unclean.has(file))
      errors.push(`check-one-material.ts PENDING: [surface] ${file} is clean or gone now: remove it`);
  const pin = options.pin ?? ALLOWED_MAX;
  if (allowed.length > pin)
    errors.push(
      `[allowlist] ${allowed.length} backdrop filters carry one-material-allow, past the pinned ${pin}: ` +
        "the allowlist only shrinks; put the new one on .ui-glass",
    );
  else if (allowed.length < pin && options.pin === undefined)
    errors.push(
      `[allowlist] ${allowed.length} allowed now: lower ALLOWED_MAX in scripts/check-one-material.ts to ${allowed.length}`,
    );
  return { errors, allowed };
}

if (import.meta.main) {
  const { errors, allowed } = checkOneMaterial();
  if (process.argv.includes("--list")) for (const line of allowed) console.log(`allowed ${line}`);
  if (errors.length > 0) {
    console.error("One material per surface (design/glass-system.md): each floating surface draws one glass.");
    for (const line of errors) console.error(`  ${line}`);
    process.exit(1);
  }
  console.log(`check-one-material: every surface draws one material (${allowed.length} allowed non-material blurs)`);
}
