import type { Translate } from "../i18n";
import { messagePreview } from "../conversation/incomingMessage";
import type { QuestionReply } from "../question/model";
import type { AskContext } from "./context";
import type { NeedsYouAnswer, NeedsYouItem } from "./model";

/// The Debug choice `agentPane.debug.needsYou` (data-needs-you on <html>): `pinned` (the default)
/// draws each ask with its answers; `compact` one line per ask; `off` no badge at all. The host
/// also writes `off` while the App Store's Needs You item is not installed
/// (`agentPane.needsYou.enabled`, off by default): no badge, no list, and no link opens one.
export type NeedsYouMode = "pinned" | "compact" | "off";

/// Shared visibility policy for native menu descriptors.
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

/// Where the expanded row opens another chat: `right` (the default), `workspace` (jump to the tab
/// that shows the chat, in whatever workspace or window), `newWorkspace`.
export type NeedsYouPlace = "right" | "workspace" | "newWorkspace";

export type NeedsYouActions = {
  /// Sends a one-click answer; rejects when acpmux refused it.
  answer(item: NeedsYouItem, answer: NeedsYouAnswer): Promise<unknown>;
  /// Opens the chat the ask is in, at the ask.
  goTo(item: NeedsYouItem): void;
  /// Opens a side session about the asking chat (`_acpmux/btw`) beside it, its first prompt the
  /// question seeded with the ask; rejects when it could not.
  ask(item: NeedsYouItem, question: string): Promise<unknown>;
  /// Sends an expanded question's whole answer (every item, an Other text); rejects when it was
  /// refused or could not be sent from here (another chat's question opens that chat instead).
  reply?(item: NeedsYouItem, sent: QuestionReply): Promise<unknown>;
  /// The turns before the ask, for the context stage (context.ts).
  context?(item: NeedsYouItem): AskContext;
  /// Opens another chat's ask at `place`: on the right (the default, as Go to source), the
  /// workspace whose tab shows it, or a new workspace (`chat.asks.open {where}`).
  open?(item: NeedsYouItem, place: NeedsYouPlace): void;
  /// Whether `open` can open the ask's chat: another chat on this pane's own acpmux, never the chat
  /// on screen (its ask is already here) or another computer's.
  opensElsewhere?(item: NeedsYouItem): boolean;
};

/// The ask's line, shared by the web list and native descriptors: its own text, else what its
/// kind says (a permission asks to allow, anything else for an answer).
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
