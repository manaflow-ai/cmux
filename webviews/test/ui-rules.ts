// The scanner behind test/ui-rules.test.ts (plans/cmux-next/a11y-foundation.md, rules 1-3): page
// code outside src/ui must not hand-roll widget roles, tab order, key handlers or portals.
import fs from "node:fs";
import path from "node:path";

export const SRC = path.resolve(import.meta.dir, "../src");

const WIDGET_ROLES =
  "listbox|option|menu|menubar|menuitem|menuitemcheckbox|menuitemradio|combobox|grid|gridcell|row|rowgroup|columnheader|rowheader|tab|tablist|tabpanel|toolbar|tooltip|dialog|alertdialog|tree|treeitem|treegrid|slider|switch|radiogroup|radio|checkbox|button|link|spinbutton|searchbox|scrollbar|separator";

export const RULES: ReadonlyArray<{ id: string; pattern: RegExp }> = [
  // A JSX attribute, not a CSS attribute selector such as `[role='button']`.
  { id: "widget-role", pattern: new RegExp(`(?<![\\[\\w-])role=\\{?["'\`](${WIDGET_ROLES})["'\`]`) },
  { id: "widget-role", pattern: new RegExp(`setAttribute\\(\\s*["']role["']\\s*,\\s*["'](${WIDGET_ROLES})["']`) },
  { id: "tab-index", pattern: /\btabIndex=|\.tabIndex\s*=|setAttribute\(\s*["']tabindex["']/ },
  { id: "key-handler", pattern: /\bon(KeyDown|KeyUp|KeyPress)(Capture)?=/ },
  { id: "key-handler", pattern: /addEventListener\(\s*["'](keydown|keyup|keypress)["']/ },
  { id: "portal", pattern: /\bcreatePortal\(|document\.body\.(append|appendChild|prepend)\(/ },
];

/** A line (or the comment line above it) marked `ui-allow: <reason>` is exempt. */
const ALLOW = /ui-allow:\s*\S/;

export interface Violation {
  file: string;
  line: number;
  rule: string;
  text: string;
}

function pageFiles(dir: string): string[] {
  const out: string[] = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (entry.name === "generated" || full === path.join(SRC, "ui")) continue;
      out.push(...pageFiles(full));
    } else if (
      /\.(ts|tsx)$/.test(entry.name) &&
      !/\.test\.(ts|tsx)$/.test(entry.name) &&
      !entry.name.endsWith(".d.ts")
    ) {
      out.push(full);
    }
  }
  return out;
}

export function scan(): Violation[] {
  const violations: Violation[] = [];
  for (const file of pageFiles(SRC)) {
    const lines = fs.readFileSync(file, "utf8").split("\n");
    lines.forEach((text, index) => {
      if (ALLOW.test(text) || (index > 0 && ALLOW.test(lines[index - 1]) && lines[index - 1].trim().startsWith("//")))
        return;
      for (const rule of RULES) {
        if (rule.pattern.test(text)) {
          violations.push({ file: path.relative(SRC, file), line: index + 1, rule: rule.id, text: text.trim() });
          break;
        }
      }
    });
  }
  return violations;
}

/** Violations per file, sorted. */
export function counts(violations: readonly Violation[]): Record<string, number> {
  const map: Record<string, number> = {};
  for (const violation of violations) map[violation.file] = (map[violation.file] ?? 0) + 1;
  return Object.fromEntries(Object.entries(map).sort(([a], [b]) => a.localeCompare(b)));
}
