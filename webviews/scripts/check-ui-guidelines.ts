// Compact-control rules from design/ui-guidelines.md. The checker intentionally starts with the
// composer-hat tray because its chevron and status mark are the surface that prompted the guideline.
// test/check-ui-guidelines.test.ts exercises the before and after declarations.
import { readFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const CSS = join(ROOT, "src/agent-session/acpmux/subagents/subagents.css");
const SPACING_TOKEN = "var(--ds-space-2)";
const CONTROL_TOKEN = "var(--acpmux-tray-pull-control-height)";
const MAX_RAW_DURATION_MS = 200;

export type UiGuidelineFinding = { rule: string; line: number; detail: string };
type Rule = { selector: string; body: string; bodyStart: number };

function lineAt(text: string, offset: number): number {
  return text.slice(0, offset).split("\n").length;
}

function cssRules(text: string): Rule[] {
  const plain = text.replace(/\/\*[\s\S]*?\*\//g, (comment) => comment.replace(/[^\n]/g, " "));
  const rules: Rule[] = [];
  const pattern = /([^{}]+)\{([^{}]*)\}/g;
  for (let match = pattern.exec(plain); match; match = pattern.exec(plain)) {
    const selector = match[1]!.trim();
    if (!selector || selector.startsWith("@")) continue;
    rules.push({ selector, body: match[2]!, bodyStart: match.index + match[0].indexOf("{") + 1 });
  }
  return rules;
}

function declaration(rule: Rule, property: string): { value: string; offset: number } | undefined {
  const match = new RegExp(`(?:^|;)\\s*${property}\\s*:\\s*([^;]+)`).exec(rule.body);
  return match
    ? { value: match[1]!.trim(), offset: rule.bodyStart + match.index + match[0].indexOf(match[1]!) }
    : undefined;
}

function hasSelector(rule: Rule, selector: RegExp): boolean {
  return selector.test(rule.selector);
}

function rawDurations(value: string): number[] {
  return [...value.matchAll(/(\d+(?:\.\d+)?)ms/g)].map((match) => Number(match[1]));
}

/** Find spacing, hit-target and motion violations in one stylesheet. */
export function findUiGuidelineViolations(file: string, text: string): UiGuidelineFinding[] {
  const findings: UiGuidelineFinding[] = [];
  const add = (rule: string, offset: number, detail: string) =>
    findings.push({ rule, line: lineAt(text, offset), detail });
  for (const cssRule of cssRules(text)) {
    if (hasSelector(cssRule, /\.acpmux-tray-pull__slot\[data-shown\]/)) {
      const width = declaration(cssRule, "width");
      if (!width || !width.value.includes(SPACING_TOKEN) || width.value.includes("var(--ds-space-1)"))
        add("spacing", width?.offset ?? cssRule.bodyStart, "the chevron/status-mark gap must use var(--ds-space-2)");
    }
    if (hasSelector(cssRule, /\.acpmux-tray-pull__tab(?:[.:#\s,]|$)/)) {
      const height = declaration(cssRule, "height");
      if (height) {
        const px = /^(\d+(?:\.\d+)?)px$/.exec(height.value);
        const valid = height.value.includes(CONTROL_TOKEN) || (px && Number(px[1]) >= 24);
        if (!valid) add("hit-target", height.offset, "the pull-tab hit target must be at least 24px high");
      }
    }
    if (
      hasSelector(cssRule, /\.acpmux-tray-pull__slot(?:[.:#\s,]|$)/) ||
      hasSelector(cssRule, /\.acpmux-tray-pull__tab(?:[.:#\s,]|$)/)
    ) {
      const transition = declaration(cssRule, "transition");
      if (transition) {
        const long = rawDurations(transition.value).find((duration) => duration > MAX_RAW_DURATION_MS);
        if (long !== undefined)
          add("animation-duration", transition.offset, `raw transition duration ${long}ms exceeds 200ms`);
      }
    }
  }
  return findings;
}

export function checkUiGuidelines(file: string = CSS): UiGuidelineFinding[] {
  return findUiGuidelineViolations(relative(ROOT, file), readFileSync(file, "utf8"));
}

if (import.meta.main) {
  const findings = checkUiGuidelines();
  for (const finding of findings) console.error(`ui guideline: ${finding.rule} ${finding.detail} (${finding.line})`);
  if (findings.length) process.exitCode = 1;
  else console.log("UI guidelines checked: spacing, hit targets and animation durations are within the design scale.");
}
