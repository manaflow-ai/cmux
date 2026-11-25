// The command rules a person configures (`agentPane.display.commandLabels` in cmux-next.json, which
// the host sends with the chat's other keys; Swift CommandLabelsSetting checks its shape). Each
// item is either a preset's name (commandRulePresets.ts) or a rule of their own:
//
//   "commandLabels": [
//     "cmux-fleet",
//     { "program": "deploy", "match": "^deploy (\\S+)", "label": "Deploying {1}",
//       "link": "https://deploys.example.com/{1}", "icon": "cloud" }
//   ]
//
// A rule of one's own:
// - `program`: the program it is about (a path's basename), or a list of them. Without one,
//   `match` is tried on every command.
// - `match`: a JavaScript regular expression, tried on the command cut to its program and that
//   program's arguments, joined by spaces (commandRules.ts `programWords`: no `cd X &&`, env
//   prefix, redirection or pipe). Without one, every command of `program` matches.
// - `label`: the line's words. `{0}` is the whole match, `{1}` and on its groups, `{name}` a named
//   group.
// - `link` (optional): a web address made the same way; only an http or https one is kept.
// - `icon` (optional): an icon name (icons/cmuxIcons.json), the terminal glyph by default.
// Items run in their order (for a command, the rules naming its program before those with only a
// pattern), before the built-in rules; one that is not a known preset or a valid
// rule is skipped, as is a pattern that does not compile.
import { chatDisplayValues, COMMAND_LABELS_KEY } from "../chatDisplay";
import { COMMAND_RULE_PRESETS } from "./commandRulePresets";
import type { CommandRule } from "./commandRules";

export { COMMAND_LABELS_KEY };

/// The longest command text a pattern of one's own is tried on, so a pattern that backtracks
/// cannot stall the tray on a huge line.
const MATCH_MAX = 2000;

const text = (value: unknown): string | undefined => (typeof value === "string" && value.trim() ? value : undefined);

/// `template` with `{0}`, `{1}` and `{name}` filled from `match`; a missing group is empty.
const fill = (template: string, match: RegExpExecArray) =>
  template.replace(/\{(\w+)\}/g, (_, name: string) =>
    /^\d+$/.test(name) ? (match[Number(name)] ?? "") : (match.groups?.[name] ?? ""),
  );

/// One rule of a person's own, or undefined when `value` is not one.
export function configuredRule(value: unknown, index: number): CommandRule | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const item = value as Record<string, unknown>;
  const label = text(item.label);
  const programs = (Array.isArray(item.program) ? item.program : [item.program]).filter(
    (program): program is string => typeof program === "string" && program.trim() !== "",
  );
  const source = text(item.match);
  if (!label || (!programs.length && !source)) return undefined;
  let pattern: RegExp | undefined;
  if (source) {
    try {
      pattern = new RegExp(source);
    } catch {
      return undefined;
    }
  }
  const link = text(item.link);
  return {
    id: `configured-${index}`,
    ...(programs.length ? { program: programs } : {}),
    icon: text(item.icon) ?? "terminal",
    read: (words) => {
      const line = words.join(" ").slice(0, MATCH_MAX);
      // Without a pattern the whole line is the match (`{0}`).
      const match = pattern ? pattern.exec(line) : /^.*$/s.exec(line);
      if (!match) return undefined;
      const said = fill(label, match).trim();
      if (!said) return undefined;
      const url = link ? fill(link, match) : undefined;
      return { text: said, ...(url && /^https?:\/\/\S+$/i.test(url) ? { link: { url } } : {}) };
    },
  };
}

/// The rules a `commandLabels` value lists: presets expanded, rules of one's own compiled, the rest
/// skipped.
export function configuredCommandRules(value: unknown): readonly CommandRule[] {
  if (!Array.isArray(value)) return [];
  const rules: CommandRule[] = [];
  value.forEach((item, index) => {
    if (typeof item === "string") {
      const preset = Object.hasOwn(COMMAND_RULE_PRESETS, item) ? COMMAND_RULE_PRESETS[item] : undefined;
      if (preset) rules.push(...preset);
      return;
    }
    const rule = configuredRule(item, index);
    if (rule) rules.push(rule);
  });
  return rules;
}

let lastValue: unknown;
let lastRules: readonly CommandRule[] = [];

/// The rules cmux-next.json configures now, compiled once per value the host sends.
export function currentCommandRules(): readonly CommandRule[] {
  const value = chatDisplayValues()[COMMAND_LABELS_KEY];
  if (value !== lastValue) {
    lastValue = value;
    lastRules = configuredCommandRules(value);
  }
  return lastRules;
}
