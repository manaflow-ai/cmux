// Which of the hat's questions the person put away (HatQuestions.tsx, its × or Escape; Leo,
// 2026-11-11: "there's no close button :("). A dismissal is kept as the pinned asks' are
// (conversation/waitingAskStore.ts): by chat, on this device, across a reload. A tagged ask's key is
// its card's (`answerKey`), so putting it away from the hat puts its pinned copy away too, and one
// dismissed from the pinned card leaves the hat; any other question's is its id. Only the hat forgets
// it: the ask still waits where it was asked.
import type { HatQuestion } from "./hatModel";

export const hatSeenKey = (question: HatQuestion): string => question.answerKey ?? `hat\u0000${question.id}`;

/// `questions` without the ones the person put away; the same list when none was.
export function unseenHatQuestions(
  questions: readonly HatQuestion[],
  dismissed: ReadonlySet<string>,
): readonly HatQuestion[] {
  if (!dismissed.size) return questions;
  const kept = questions.filter((question) => !dismissed.has(hatSeenKey(question)));
  return kept.length === questions.length ? questions : kept;
}
