import type { Translate } from "../i18n";
import type { NeedsYouAnswer, NeedsYouItem } from "./model";

/// The Debug choice `agentPane.debug.needsYou` (data-needs-you on <html>): `pinned` (the default)
/// draws each ask with its answers; `compact` one line per ask; `off` no badge at all.
export type NeedsYouMode = "pinned" | "compact" | "off";

/// Shared visibility policy for DOM rows and native menu descriptors.
export function needsYouModeCapabilities(mode: NeedsYouMode): {
  readonly answers: boolean;
  readonly askAbout: boolean;
  readonly goToSource: boolean;
  readonly detail: boolean;
} {
  return {
    answers: mode === "pinned",
    askAbout: mode === "pinned",
    goToSource: mode !== "off",
    detail: mode === "pinned",
  };
}

export function needsYouMode(
  root: { dataset: DOMStringMap } | undefined = globalThis.document?.documentElement,
): NeedsYouMode {
  const value = root?.dataset.needsYou;
  return value === "off" || value === "compact" ? value : "pinned";
}

export type NeedsYouActions = {
  answer(item: NeedsYouItem, answer: NeedsYouAnswer): Promise<unknown>;
  goTo(item: NeedsYouItem): void;
  ask(item: NeedsYouItem, question: string): Promise<unknown>;
};

/// The ask's one-line label, shared by the web list and native descriptors.
export function askText(item: NeedsYouItem, t: Translate): string {
  if (item.kind === "held") return t("needsYou.held", { n: item.held ?? 1, peer: item.ask });
  return item.ask || t(item.kind === "approval" ? "needsYou.waitingPermission" : "needsYou.waiting");
}

/// The side session's first prompt (`_acpmux/btw`), kept independent of the Needs You UI bundle.
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
