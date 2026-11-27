import { createContext } from "react";
import type { ComposerAttachment } from "../attachments";
import type { AcpmuxRow } from "../model";
import { type TakeBack } from "./turnActions";

/// Under a steer the agent has not read yet: a quiet clock (it reads a steer when its current
/// step ends), Send now, which stops that step so the agent reads the message at once, and an X
/// that takes the steer back to edit (Leo, 2026-10-21: "THERE'S A CANCEL AND EDIT BY CLICKING THE
/// X BUTTON ON THE SENT MESSAGES TO CLAUDE.. THEY'RE STEERS BUT THEY HAVENT BEEN SENT SOMETIMES
/// WITH THE TOOL CALLS AND WHATNOT WAITING"). The turn goes on; only Stop ends it (Leo,
/// 2026-10-20). An agent that cannot stop one step reads it when the step ends, as before. `send`
/// is `_acpmux/queue_edit` `send_now` with the steer's own promptId; it answers false once the
/// steer was read. The X is the page's `unsteer` (`takeBackSteer`), where the chat offers it.
/// Queue controls replace normal hover actions until Send now is accepted or the agent reads it.
/// The row is Claude desktop's: Copy, Retry and Fork (the sent row's own buttons, `queued`, where
/// that row offers them) and the X show on hover, and Send now comes last, shown at rest too (Leo,
/// 2026-11-03: "the copy is always showing for no reason... plus the order is wrong"). Copy keeps a
/// waiting steer copyable as any message is (Leo, 2026-10-29: "i feel like im frequently missing
/// the copy/whatever buttons on these steers").
/// A refusal keeps the controls available. Accepted delivery removes them in the same render.
/// An X acpmux refuses never does nothing: the row says "Read after this step", so it says why the
/// message stays (Leo, 2026-10-29: "this fucking edit message thing. It doesn't even fucking work").
/// The X stays beside it, as does one that failed on the way (an RPC error, attachments not read):
/// acpmux also refuses for a moment right after the steer is sent, before it has registered it
/// (it prepares the steer's large images first), and a later click takes the steer back then.
/// While several of the person's steers wait, the row of the newest (snapshot `newestOwnSteer`):
/// only it offers Send now. Send now stops the agent's current step and the agent then reads every
/// waiting steer, so a Send now under each read as if each were held in a queue (Leo, 2026-11-01:
/// "why are ALL of these send now???? aren't these steers???"). Undefined (one waits): its own.
export const NewestSteerContext = createContext<string | undefined>(undefined);

/// The chat the rows belong to (snapshot `sessionId`): the page switches chats in place, so what a
/// Send now covered is kept per chat (cmux#32846). Empty where one chat is drawn.
export const SteerChatContext = createContext("");

/// The prompts whose Send now worked, by promptId, so a row drawn again while acpmux still says the
/// steer waits (scrolled away and back) shows no controls. One id per click, for the page's life.
/// `coveredAt`: the time of the newest steer whose Send now worked while several waited. Send now
/// stops the agent's step and the agent then reads every waiting steer, so the earlier ones it
/// covered (sent at or before it) drop their X and Copy line with it instead of looking held back
/// (Leo, 2026-11-03: "this looks kinda weird when i send now and there was a previously steered
/// message"). A steer sent later waits on its own. Kept per chat (`SteerChatContext`): the page
/// switches chats in place, and another chat's steers were never covered (cmux#32846).
/// A covered steer drops its X even when the agent cannot stop its current step: acpmux would still
/// take it back until the step ends, but it goes in with the Send now the person chose, and an X
/// left under it looked like a message held back.
export let sentNowState = { ids: new Set<string>(), coveredAt: new Map<string, number>() };
export const sentNowListeners = new Set<() => void>();
export function publishSentNow(next: typeof sentNowState): void {
  sentNowState = next;
  for (const listener of sentNowListeners) listener();
}
/// A `send_now` acpmux accepted for `promptId`, from any control (App.tsx `editQueued`).
export function markSentNow(promptId: string): void {
  if (!sentNowState.ids.has(promptId))
    publishSentNow({ ...sentNowState, ids: new Set(sentNowState.ids).add(promptId) });
}

/// Whether the chat's X takes a waiting steer back (`_acpmux/steer_withdraw`): only acpmux's Claude
/// Code adapter does. acpmux's `backgroundsWork` marks a chat that runs it, whatever its family is
/// named (Leo's claude-sr2); `steering` alone does not, as other ACP agents steer too.
export function takesSteersBack(summary: { backgroundsWork?: boolean } | undefined, connected: boolean): boolean {
  return connected && summary?.backgroundsWork === true;
}

/// Takes back steer `row` while the agent has not read it: acpmux drops it (`withdraw`), and its
/// text and attachments go back into the composer to edit (`back`). Its attachments are read first
/// (the row goes with acpmux's `steer_withdrawn` record), and one that cannot be read keeps the
/// steer: the composer never gets the text without its images (`failed`, as is a withdraw that
/// never got its answer). `refused` when acpmux answered that the steer stays, or it was read.
export async function takeBackSteer(
  row: AcpmuxRow,
  io: {
    withdraw: (promptId: string) => Promise<boolean>;
    attachments: (rowId: string) => Promise<ComposerAttachment[]>;
    draft?: (rowId: string, text: string) => Promise<{ input: string; attachments: ComposerAttachment[] }>;
    restore: (text: string, attachments: ComposerAttachment[]) => void;
  },
): Promise<TakeBack> {
  const promptId = row.steerPromptId;
  if (!promptId || row.steer !== "waiting") return "refused";
  const text = row.resend ?? row.text ?? "";
  const draft = await (
    io.draft ? io.draft(row.id, text) : io.attachments(row.id).then((attachments) => ({ input: text, attachments }))
  ).catch(() => undefined);
  const attachments = draft?.attachments;
  // An image acpmux could not give back is left out of what it read: the steer stays then too.
  const images = attachments?.filter((attachment) => attachment.kind === "image").length ?? 0;
  if (!draft || images < (row.images?.length ?? 0)) return "failed";
  const withdrawn = await io.withdraw(promptId).catch(() => undefined);
  if (withdrawn === undefined) return "failed";
  if (!withdrawn) return "refused";
  io.restore(draft.input, draft.attachments);
  return "back";
}
