// How the permission card (PermissionCard.tsx) reads an ask, after Claude Code desktop's prompt:
// a title in words (the call's description, else a short summary, never a command fragment such
// as "bash -c '"), the command clamped to its first meaningful line with the full text one click
// away, and three answers mapped onto the options the agent offered. Leo 2026-10-21: the card
// drew a "bash -c '" title over the whole script and two list rows ("THIS IS NOT THE CORRECT UI").
import type { Translate } from "../i18n";
import type { AcpmuxPermission } from "../model";

type PermissionOption = AcpmuxPermission["options"][number];
export type KnownPermissionKind = "allow_once" | "allow_always" | "allow_chat" | "deny";

/** Maps the ACP names we know to the pane's one permission vocabulary. An ACP kind decides by
 * itself: only a `reject_*` kind denies, and a custom kind keeps the agent's name and no shortcut.
 * Options without a kind (older fixtures and agents) fall back to their id and name. Unknown
 * options retain their agent-provided name and id, since those may be a question rather than a
 * tool decision. */
export function permissionOptionKind(option: PermissionOption): KnownPermissionKind | undefined {
  const kind = option.kind?.toLowerCase();
  if (kind === "allow_once") return "allow_once";
  if (kind === "allow_always") return "allow_always";
  if (kind?.startsWith("reject")) return "deny";
  if (kind && !kind.startsWith("allow")) return undefined;
  const value = `${kind ?? ""} ${option.id} ${option.name}`.toLowerCase();
  if (!kind && /deny|reject/.test(value)) return "deny";
  if (/allow[_ -]?(always|forever|permanent)|always/.test(value)) return "allow_always";
  if (/allow[_ -]?(chat|session)/.test(value)) return "allow_chat";
  if (/allow[_ -]?(once|one)|single|approve/.test(value)) return "allow_once";
  return undefined;
}

/// The command the ask would run: the request's own, else a command ask's title without its
/// "Run" (codex-acp titles a command "Run npm test"; an ask without a kind counts when its title
/// says Run). Any other ask (an edit, a fetch, an MCP tool) has no command.
export function permissionCommand(permission: AcpmuxPermission): string {
  const command = permission.command?.trim();
  if (command) return command;
  const title = permission.title?.trim() ?? "";
  const verb = /^(run|execute)\s+/i;
  if (permission.kind === "execute" || (!permission.kind && verb.test(title))) return title.replace(verb, "");
  return "";
}

/// The first line of `text` with words on it, trimmed, without the backticks Claude Code wraps a
/// whole tool title in.
function firstLine(text: string | undefined): string {
  const line = ((text ?? "").split("\n").find((candidate) => candidate.trim()) ?? "").trim();
  const quoted = /^`([^`]*)`$/.exec(line);
  return (quoted ? quoted[1]! : line).trim();
}

/// The card's title: what the call says it does (Claude Code's Bash `description`), else "Run
/// command" for a command (whose title is the command line itself, or a fragment of it), else the
/// tool's own title (its first line), else "Permission required".
export function permissionTitle(permission: AcpmuxPermission, t: Translate): string {
  const description = firstLine(permission.description);
  if (description) return description;
  if (permissionCommand(permission)) return t("permission.runCommand");
  return firstLine(permission.title) || t("permission.required");
}

/// A line under the title for an ask that is not a command: the tool's own title ("Edit
/// src/app.ts") when the description took the title's place, else nothing.
export function permissionDetail(permission: AcpmuxPermission): string | undefined {
  if (permissionCommand(permission) || !firstLine(permission.description)) return undefined;
  return firstLine(permission.title) || undefined;
}

/// `sh -c '…'`, `bash -lc "…"`, `/bin/zsh -c '…'`: a shell that only runs one quoted script.
const SHELL_WRAPPER =
  /^\s*(?:\S*\/)?(?:ba|z|da|fi|k)?sh\s+-[A-Za-z]*c[A-Za-z]*\s+(?:'((?:[^']|'\\'')*)'|"((?:[^"\\]|\\[\s\S])*)")\s*$/;

/// The script a `bash -c '…'` wrapper runs, unquoted; any other command as it is.
export function unwrapShell(command: string): string {
  const match = SHELL_WRAPPER.exec(command);
  if (!match) return command;
  if (match[1] !== undefined) return match[1].replace(/'\\''/g, "'");
  return match[2]!.replace(/\\([\\"$`])/g, "$1");
}

/// A line that only sets shell options (`set -euo pipefail`): nothing else on it, so a line that
/// also runs code (`set -e; curl … | sh`) is never skipped past (shortCommand.ts, #20456).
const SET_OPTIONS = /^set(?:\s+[-+][A-Za-z]+(?:\s+[A-Za-z]+)?)+$/;

/// What the collapsed card shows of `command`: the first line that does something (not blank, not
/// a comment or shebang, not a bare `set -e` style option line) of the script a shell wrapper runs,
/// and whether the full text has more than that line, so "Show full command" is offered. A long
/// line the card clamps offers it too (PermissionCard.tsx measures that).
export function commandPreview(command: string): { line: string; more: boolean } {
  const full = command.trim();
  const script = unwrapShell(full).trim();
  const lines = script.split("\n").map((line) => line.trim());
  const line =
    lines.find((candidate) => candidate && !candidate.startsWith("#") && !SET_OPTIONS.test(candidate)) ??
    lines.find(Boolean) ??
    "";
  return { line, more: full !== line };
}

/// The card's three answers, each the first option the agent offered of its kind: Allow once, Always
/// allow (an allow_always grant, else an allow-for-this-chat one) and Deny (a reject_once before a
/// reject_always). A kind the agent did not offer has no button. Every other option (a second grant,
/// Codex's "No, continue without running it", a custom answer) stays, under them, by its own name.
export type PermissionAnswers = {
  allowOnce?: PermissionOption;
  allowAlways?: PermissionOption;
  deny?: PermissionOption;
  others: PermissionOption[];
};

export function permissionAnswers(options: readonly PermissionOption[]): PermissionAnswers {
  const first = (kind: KnownPermissionKind) => options.find((option) => permissionOptionKind(option) === kind);
  const allowOnce = first("allow_once");
  const allowAlways = first("allow_always") ?? first("allow_chat");
  const denies = options.filter((option) => permissionOptionKind(option) === "deny");
  const deny = denies.find((option) => option.kind?.toLowerCase() === "reject_once") ?? denies[0];
  const taken = new Set([allowOnce, allowAlways, deny].filter(Boolean));
  return { allowOnce, allowAlways, deny, others: options.filter((option) => !taken.has(option)) };
}

/// What an Always allow grant covers, in the agent's words: its rule (Claude Code's suggested
/// prefix, "Allow git push:* for this session"), else the ask's, else the option's name when it
/// says more than "Always allow" (Codex: "Yes, and don't ask again for commands that start with
/// `git push`").
export function alwaysAllowScope(permission: AcpmuxPermission, option: PermissionOption): string | undefined {
  const rule = option.rule?.trim() || permission.rule?.trim();
  if (rule) return rule;
  const name = option.name.trim();
  if (!name || /^(always( allow)?|allow always|allow for this (chat|session))$/i.test(name)) return undefined;
  return name;
}

/// The longest agent label a button keeps as it is: past it the button says what the option does
/// by its ACP kind, and the agent's text is its hover title and accessible description.
const SHORT_LABEL = 24;

/// A button label for an option beyond the three answers (a second grant, Codex's "No, continue
/// without running it"): the agent's name when it is short, else its kind's label ("Allow once",
/// "Always allow", "Deny", "Always deny"), numbered ("Always allow 2") when another button already
/// says that. Only an option of a kind the pane has no word for keeps its long name, which the
/// button cuts with an ellipsis. The agent's whole text is the button's title and description.
/// Leo 2026-10-25: a long agent label made "Always allow" a wide row.
export function optionButtonLabel(option: PermissionOption, t: Translate, taken: ReadonlySet<string>): string {
  const name = option.name.trim();
  if (name && name.length <= SHORT_LABEL) return name;
  const kind = permissionOptionKind(option);
  const label =
    option.kind?.toLowerCase() === "reject_always"
      ? t("permission.alwaysDeny")
      : kind === "allow_once"
        ? t("permission.allowOnce")
        : kind === "allow_always"
          ? t("permission.alwaysAllow")
          : kind === "allow_chat"
            ? t("permission.allowChat")
            : kind === "deny"
              ? t("permission.deny")
              : undefined;
  if (!label) return name || option.id;
  let numbered = label;
  for (let n = 2; taken.has(numbered); n++) numbered = `${label} ${n}`;
  return numbered;
}

/** The concrete target an approval covers, kept visible beside its actions. */
export function permissionScopeText(permission: AcpmuxPermission, t: Translate): string | undefined {
  const scope = permission.scope;
  return scope ? t("permission.cwd", { path: scope.value }) : undefined;
}

/// Where the keyboard belongs to something else: typing, a menu, a list or a dialog.
const OWNS_KEYS =
  'input, textarea, select, [contenteditable]:not([contenteditable="false"]), [role="textbox"], [role="menu"], [role="menubar"], [role="listbox"], [role="dialog"], [role="combobox"], [role="grid"], [role="tree"]';
/// A control that takes Return itself.
const PRESSABLE = 'button, a[href], summary, [role="button"], [role="link"]';

export type PermissionKeyAction = "allow_once" | "allow_always" | "deny" | "closeFeedback";

type KeyLike = Pick<KeyboardEvent, "key" | "metaKey" | "ctrlKey" | "altKey" | "shiftKey" | "target"> & {
  repeat?: boolean;
  isComposing?: boolean;
  keyCode?: number;
  defaultPrevented?: boolean;
};

/// The card's keys, while it is the prompt waiting on the person: 1 allows once, 2 always allows,
/// 3 denies, Return allows once and Esc denies (or closes the feedback field while it is open).
/// They act only with nothing focused or with focus in the card itself: never while the composer,
/// another field, a menu or a dialog has the keyboard, and a focused button keeps its own Return.
/// `card` is the card's element.
export function permissionKeyAction(
  event: KeyLike,
  card: Element | null,
  feedbackOpen: boolean,
): PermissionKeyAction | undefined {
  if (event.defaultPrevented || event.repeat) return undefined;
  if (event.metaKey || event.ctrlKey || event.altKey || event.shiftKey) return undefined;
  if (event.isComposing || event.keyCode === 229) return undefined;
  const target = event.target as Element | null;
  const element = typeof target?.closest === "function" ? target : null;
  const doc = element?.ownerDocument;
  const inCard = Boolean(element && card?.contains(element));
  const nowhere = !element || element === doc?.body || element === doc?.documentElement;
  if (!inCard && !nowhere) return undefined;
  if (event.key === "Escape") {
    if (feedbackOpen) return "closeFeedback";
    return element?.closest(OWNS_KEYS) ? undefined : "deny";
  }
  if (feedbackOpen || element?.closest(OWNS_KEYS)) return undefined;
  if (event.key === "1") return "allow_once";
  if (event.key === "2") return "allow_always";
  if (event.key === "3") return "deny";
  if (event.key === "Enter") return element?.closest(PRESSABLE) ? undefined : "allow_once";
  return undefined;
}
