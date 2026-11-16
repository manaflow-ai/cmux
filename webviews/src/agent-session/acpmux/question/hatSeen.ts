// Which of the hat's questions the person put away (HatQuestions.tsx, its × or Escape; Leo,
// 2026-11-11: "there's no close button :("). A dismissal is kept as the pinned asks' are
// (conversation/waitingAskStore.ts): by chat, on this device, across a reload. A tagged ask's key is
// its card's (`answerKey`), so putting it away from the hat puts its pinned copy away too, and one
// dismissed from the pinned card leaves the hat; any other question's is its id. Only the hat forgets
// it: the ask still waits where it was asked.
import { askKey } from "../conversation/waitingAskStore";
import type { AcpmuxRow } from "../model";
import { askItemId } from "../needsYou/model";
import type { ChildAsk } from "../subagents/childAsks";
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

/// The keys of the questions a card in the asks stack over the composer already shows, as the hat
/// names them (`hatCardKey`): every pinned tagged ask (conversation/PendingAsks.tsx, by its card key,
/// waitingAskStore.ts `askKey`) and the sub-session's ask its card shows (subagents/ChildAsk.tsx, by
/// the Needs you id of its permission, needsYou/model.ts `askItemId`).
export function stackCardKeys(pinned: readonly AcpmuxRow[], childAsk: ChildAsk | undefined): ReadonlySet<string> {
  if (!pinned.length && !childAsk) return NO_KEYS;
  const keys = new Set(pinned.map(askKey));
  if (childAsk) keys.add(askItemId(childAsk.ask.permission.permissionId));
  return keys;
}
const NO_KEYS: ReadonlySet<string> = new Set();

/// How a card in the asks stack names a question the hat also holds: a tagged ask by its card key,
/// a started chat's by its Needs you id (`acpmux:<permission>`).
export const hatCardKey = (question: HatQuestion): string => question.answerKey ?? question.id;

/// The hat's questions as it draws them: without the ones the person put away, and without the ones
/// a card in the asks stack already shows. One ask renders once (Leo, 2026-11-15, on a tagged ask
/// drawn both pinned and in the hat: "there should not be 2 of these"). The card stays: it holds the
/// composer's ⌘↩ and its Dismiss, as the chat's own question's card does (hatModel.ts `onCard`); the
/// hat keeps stepping through every other question. The same list when nothing leaves.
export function hatQuestionsShown(
  questions: readonly HatQuestion[],
  dismissed: ReadonlySet<string>,
  onStack: ReadonlySet<string>,
): readonly HatQuestion[] {
  const unseen = unseenHatQuestions(questions, dismissed);
  if (!onStack.size) return unseen;
  const kept = unseen.filter((question) => !onStack.has(hatCardKey(question)));
  return kept.length === unseen.length ? unseen : kept;
}
