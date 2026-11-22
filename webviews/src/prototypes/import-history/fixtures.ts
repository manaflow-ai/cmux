// l10n-allow-file: isolated gallery prototype (fixture counts), not shipped UI.
// Where "Bring your history" is offered without being hidden (David Beyer, Nov 20: "Bring your history is
// oddly hidden and ties memory to the Chief only"; 51c16e53f858 removed it). One offer, three placements:
// the Chief's first turn, a Settings card outside Chief, and a New Tab chip. Counts are sample numbers.
import type { ImportCardData, ImportCardList } from "../../ui/ImportCards";

export const HISTORY_COUNTS = { claudeSessions: 412, codexThreads: 88, memoryNotes: 37 } as const;

export const HISTORY_FACTS = `${HISTORY_COUNTS.claudeSessions} Claude Code sessions · ${HISTORY_COUNTS.codexThreads} Codex threads · ${HISTORY_COUNTS.memoryNotes} memory notes`;

/// One card for both tools (the old page had one row per tool): one button brings all of it in.
export const HISTORY_CARD: ImportCardData = {
  id: "agents.history",
  kind: "agentHistory",
  title: "Bring in your Claude and Codex history",
  facts: HISTORY_FACTS,
  benefit:
    "Old chats become searchable here, and every agent, the Chief included, starts out knowing your projects and preferences. Passwords and API keys are never copied, and you can undo it.",
  state: "ready",
  primary: { action: "start", title: "Bring It In" },
  secondary: [{ action: "dismiss", title: "Not Now" }],
  dismissed: false,
};

/// The same card after its button: the import runs in the background.
export const HISTORY_CARD_RUNNING: ImportCardData = {
  ...HISTORY_CARD,
  state: "running",
  progress: 0.38,
  status: "Reading 412 Claude Code sessions… You can keep working.",
  secondary: [],
};
delete HISTORY_CARD_RUNNING.primary;

export const historyList = (card: ImportCardData = HISTORY_CARD, title = ""): ImportCardList => ({
  title,
  cards: [card],
});
