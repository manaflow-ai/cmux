import { type Translate } from "../i18n";
import type { NeedsYouItem } from "./model";
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
