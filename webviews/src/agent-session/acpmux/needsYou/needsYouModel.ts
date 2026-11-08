import { type Translate } from "../i18n";
import type { NeedsYouAnswer, NeedsYouItem } from "./model";
import { messagePreview } from "../conversation/incomingMessage";

/// The Debug choice `agentPane.debug.needsYou` (data-needs-you on <html>): `pinned` (the default)
/// draws each ask with its answers; `compact` one line per ask; `off` no badge at all. The host
/// also writes `off` while the App Store's Needs You item is not installed
/// (`agentPane.needsYou.enabled`, off by default): no badge, no list, and no link opens one.
export type NeedsYouMode = "pinned" | "compact" | "off";

export function needsYouMode(
  root: { dataset: DOMStringMap } | undefined = globalThis.document?.documentElement,
): NeedsYouMode {
  const value = root?.dataset.needsYou;
  return value === "off" || value === "compact" ? value : "pinned";
}

/// The ask's line: its own text, else what its kind says (a permission asks to allow, anything
/// else for an answer).
export function askText(item: NeedsYouItem, t: Translate): string {
  // A guest's held prompt reads as its text, as a question reads as its prompt.
  if (item.kind === "held" && item.promptId) return messagePreview(item.ask);
  if (item.kind === "held") return t("needsYou.held", { n: item.held ?? 1, peer: item.ask });
  return item.ask || t(item.kind === "approval" ? "needsYou.waitingPermission" : "needsYou.waiting");
}

/// The side session's first prompt (`_acpmux/btw`): the ask, then the person's question, so the
/// side session answers about this ask from the chat's conversation without the chat re-reading.
export function sideQuestionPrompt(item: NeedsYouItem, question: string): string {
  // l10n-allow: a prompt to the agent, never shown to the person
  const lines = [
    "I am about to answer an open ask from this chat and want to understand it first.",
    `The ask (${item.kind}): ${item.ask || "waiting for my answer"}`,
    ...(item.detail ? [`Details: ${item.detail}`] : []),
    ...(item.question?.items[0]?.options.length
      ? [`Choices: ${item.question.items[0].options.map((option) => option.label).join(" / ")}`]
      : []),
    `My question: ${question}`,
    "Answer briefly from what this chat has done: what the agent is doing, why it asks, and what each answer would lead to.",
  ];
  return lines.join("\n");
}

/// A permission's answer's letter, as the permission card's (permissions/prompt.ts
/// PERMISSION_LETTERS): y allows once, n denies. A question's choices and a held pair's Resume
/// have none; the list offers no lasting allow, so it has no a.
export function answerKey(item: NeedsYouItem, choice: NeedsYouAnswer): "y" | "n" | undefined {
  if (!item.permissionId || item.question || item.kind === "held") return undefined;
  return choice.tone === "allow" ? "y" : choice.tone === "deny" ? "n" : undefined;
}

/// Where the keyboard belongs to a field or a picker in the list (Ask about this, a question's form).
const TYPES_HERE =
  'input, textarea, select, [contenteditable]:not([contenteditable="false"]), [role="textbox"], [role="menu"], [role="listbox"], [role="combobox"]';

/// The answer button a key presses in the list: y or n answers the row that has focus, or the top
/// row with a lettered answer when the list itself has it. None while a field has the keyboard.
export function keyedAnswer(
  event: Pick<KeyboardEvent, "key" | "metaKey" | "ctrlKey" | "altKey" | "shiftKey" | "target"> & {
    repeat?: boolean;
    isComposing?: boolean;
    keyCode?: number;
    defaultPrevented?: boolean;
  },
  panel: Element,
): HTMLButtonElement | null {
  if (event.defaultPrevented || event.repeat || event.isComposing || event.keyCode === 229) return null;
  if (event.metaKey || event.ctrlKey || event.altKey || event.shiftKey) return null;
  const key = event.key.toLowerCase();
  if (key !== "y" && key !== "n") return null;
  const target = event.target as Element | null;
  const element = typeof target?.closest === "function" ? target : null;
  if (element?.closest(TYPES_HERE)) return null;
  const rows = [...panel.querySelectorAll(".acpmux-needs-you-item")];
  const row =
    element?.closest(".acpmux-needs-you-item") ?? rows.find((each) => each.querySelector("[data-answer-key]"));
  return row?.querySelector<HTMLButtonElement>(`button[data-answer-key="${key}"]:not(:disabled)`) ?? null;
}
