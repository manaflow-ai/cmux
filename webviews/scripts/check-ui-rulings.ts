/**
 * Advisory checks for Leo's settled UI rulings.
 *
 * This command deliberately never fails the caller. It emits GitHub warning annotations for
 * status-like selectors that add a forever opacity/visibility/scale loop, so the ruling is visible
 * in lint output without becoming a brittle merge gate. Existing, intentional loops stay in the
 * allowlist below with their source and reason.
 *
 * Run from webviews with `bun run check:ui-rulings`.
 */
import { readdirSync, readFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

type Rule = { selector: string; body: string; offset: number };
type Keyframes = { name: string; body: string };
type Finding = {
  file: string;
  line: number;
  selector: string;
  keyframe: string;
  properties: string[];
};

type Allowance = {
  file: string;
  selector: string;
  keyframe: string;
  why: string;
};

type BoundaryAllowance = {
  file: string;
  selector: string;
  owner: string;
};

// These are existing loops that predate this advisory check. Keep each exception tied to a
// semantic selector and a dated Leo decision; a new status loop must be reported for review.
const ALLOWLIST: Allowance[] = [
  {
    file: "agent-session/acpmux/conversation/conversation.css",
    selector: ".cv-spinner[data-working]",
    keyframe: "cmux-breathe",
    why: "pre-existing default working-look breathe loop (Leo, 2026-10-20); retained as an explicit follow-up while the spinner ruling is reconciled",
  },
];

// Austin's Jump to latest dots are outside Leo's settled-ruling scope. Keep this boundary explicit
// so the advisory does not create a styling obligation for Austin or Lawrence's compositor work.
const OUT_OF_SCOPE: BoundaryAllowance[] = [
  {
    file: "agent-session/acpmux/conversation/conversation.css",
    selector: ".acpmux-jump-latest",
    owner: "Austin (af8fbaad) / Lawrence compositor details",
  },
];

const src = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../src");

function stylesheets(dir: string, out: string[] = []): string[] {
  for (const entry of readdirSync(dir, { withFileTypes: true }).sort((a, b) => a.name.localeCompare(b.name))) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      // Prototypes are not loaded by the app and include deliberately experimental motion.
      if (entry.name !== "prototypes") stylesheets(full, out);
    } else if (entry.name.endsWith(".css")) {
      out.push(full);
    }
  }
  return out;
}

function stripComments(css: string): string {
  return css.replace(/\/\*[\s\S]*?\*\//g, (comment) => comment.replace(/[^\n]/g, " "));
}

/** Parse ordinary rules and keyframes, retaining each ordinary rule's source offset. */
function parseStylesheet(css: string): { rules: Rule[]; keyframes: Keyframes[] } {
  const text = stripComments(css);
  const rules: Rule[] = [];
  const keyframes: Keyframes[] = [];
  const heads: { head: string; offset: number }[] = [];
  const bodies: string[] = [];
  let start = 0;
  for (let index = 0; index < text.length; index++) {
    const character = text[index];
    if (character === "{") {
      const rawHead = text.slice(start, index);
      const cut = rawHead.lastIndexOf(";");
      const head = rawHead.slice(cut + 1).trim();
      const offset = start + cut + 1 + rawHead.slice(cut + 1).search(/\S|$/);
      const named = /^@(?:-webkit-)?keyframes\s+([\w-]+)/i.exec(head);
      if (named) {
        let depth = 1;
        let end = index + 1;
        for (; end < text.length && depth > 0; end++) {
          if (text[end] === "{") depth++;
          else if (text[end] === "}") depth--;
        }
        keyframes.push({ name: named[1]!, body: text.slice(index + 1, end - 1) });
        index = end - 1;
        start = end;
        continue;
      }
      // Declarations before a nested rule belong to the enclosing rule.
      if (bodies.length && cut >= 0) bodies[bodies.length - 1] += rawHead.slice(0, cut + 1);
      heads.push({ head: head, offset: Number.isFinite(offset) ? offset : start });
      bodies.push("");
      start = index + 1;
    } else if (character === "}") {
      const current = heads.pop();
      const body = (bodies.pop() ?? "") + text.slice(start, index);
      if (current && !current.head.startsWith("@")) {
        const outer = heads
          .filter(({ head }) => !head.startsWith("@"))
          .map(({ head }) => head)
          .join(" ");
        rules.push({
          selector: outer ? `${outer} ${current.head}` : current.head,
          body,
          offset: current.offset,
        });
      }
      start = index + 1;
    }
  }
  return { rules, keyframes };
}

function declarations(body: string): { property: string; value: string }[] {
  return body
    .split(";")
    .map((part) => /^\s*([-\w]+)\s*:\s*([\s\S]*)$/.exec(part))
    .filter((match): match is RegExpExecArray => match !== null)
    .map((match) => ({ property: match[1]!.toLowerCase(), value: match[2]!.trim() }));
}

function flickerProperties(body: string): string[] {
  const properties: string[] = [];
  if (/(^|[;{\s])opacity\s*:/.test(body)) properties.push("opacity");
  if (/(^|[;{\s])visibility\s*:/.test(body)) properties.push("visibility");
  if (/(^|[;{\s])scale\s*:|scale(?:3d|X|Y)?\s*\(/.test(body)) properties.push("scale");
  if (/(^|[;{\s])transform\s*:[^;}]*(?:scale|matrix)/.test(body)) properties.push("scale");
  return [...new Set(properties)];
}

function lineAt(text: string, offset: number): number {
  return text.slice(0, offset).split("\n").length;
}

function animationNames(value: string, known: Set<string>): string[] {
  return value.match(/[A-Za-z_][\w-]*/g)?.filter((name) => known.has(name)) ?? [];
}

function isForever(decls: { property: string; value: string }[]): boolean {
  return decls.some(
    ({ property, value }) =>
      (property === "animation" || property === "animation-iteration-count") && /\binfinite\b/i.test(value),
  );
}

function statusLike(selector: string): boolean {
  // Data attributes are the stable contract for stateful indicators; class names are intentionally
  // excluded so a cosmetic rename cannot create a brittle gate.
  return /\[data-(?:working|status)(?:[=\s\]])/i.test(selector);
}

function findLoops(file: string, css: string, byName: Map<string, string>): Finding[] {
  const { rules } = parseStylesheet(css);
  const findings: Finding[] = [];
  for (const rule of rules) {
    if (!statusLike(rule.selector)) continue;
    const decls = declarations(rule.body);
    if (!isForever(decls)) continue;
    const names = decls
      .filter(({ property }) => property === "animation" || property === "animation-name")
      .flatMap(({ value }) => animationNames(value, new Set(byName.keys())));
    for (const keyframe of new Set(names)) {
      const properties = flickerProperties(byName.get(keyframe) ?? "");
      if (properties.length === 0) continue;
      findings.push({
        file,
        line: lineAt(css, rule.offset),
        selector: rule.selector.replace(/\s+/g, " ").trim(),
        keyframe,
        properties,
      });
    }
  }
  return findings;
}

function allowanceFor(finding: Finding): Allowance | undefined {
  return ALLOWLIST.find(
    (entry) =>
      entry.file === finding.file && finding.selector.includes(entry.selector) && entry.keyframe === finding.keyframe,
  );
}

function outOfScope(finding: Finding): boolean {
  return OUT_OF_SCOPE.some((entry) => entry.file === finding.file && finding.selector.includes(entry.selector));
}

const files = stylesheets(src).map((absolute) => ({
  absolute,
  relative: path.relative(src, absolute).replaceAll(path.sep, "/"),
  css: readFileSync(absolute, "utf8"),
}));
const byName = new Map<string, string>();
for (const { css } of files)
  for (const frame of parseStylesheet(css).keyframes)
    byName.set(frame.name, `${byName.get(frame.name) ?? ""}${frame.body}`);
const findings = files
  .flatMap(({ relative, css }) => findLoops(relative, css, byName))
  .filter((finding) => !outOfScope(finding));

for (const finding of findings) {
  const allowance = allowanceFor(finding);
  const title = allowance ? "Leo UI ruling (allowlisted)" : "Leo UI ruling (review)";
  const detail = allowance
    ? `${finding.selector} uses ${finding.keyframe} (${finding.properties.join(", ")}); ${allowance.why}`
    : `${finding.selector} uses ${finding.keyframe} (${finding.properties.join(", ")}); status-dot loops must be reviewed against Leo's settled ruling`;
  console.warn(`::warning file=webviews/src/${finding.file},line=${finding.line},title=${title}::${detail}`);
}

console.log(
  `ui-rulings: scanned ${files.length} stylesheet(s); ${findings.length} status-motion finding(s), all advisory (exit 0)`,
);
