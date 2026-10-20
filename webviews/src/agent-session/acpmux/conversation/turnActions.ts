// Actions a turn's footer and edited-files card offer that reach past the transcript (to the
// client). A context, so a change in what acpmux serves, or in what the reader decided about a
// turn's hunks, reaches memoized rows without changing their versions.
import { createContext } from "react";
import type { HunkReview } from "../changes/hunkReview";
import type { HarnessHealth } from "../HarnessHealthNotice";
import type { AcpmuxSnapshot } from "../model";
import type { MessageBranch } from "./branches";

export type TurnActions = {
  /// Fork the session through the turn whose summary event is `throughSeq`; absent when
  /// acpmux does not serve forks.
  fork?: (throughSeq: number) => void;
  /// The latest completed turn (`latestForkSeq`), the only one `fork` goes through unless `forkAny`.
  forkSeq?: number;
  /// Every completed turn forks (`forksAnyTurn`): acpmux forks a Claude or Codex chat through any of them (cx-yqiv, cx-a7r).
  forkAny?: boolean;
  /// Edit and resend (cx-ncc.60): the prompts that edit in place, each with the turn its edit forks
  /// through (`editableTurns`), and the send that forks there and sends the edited text.
  edit?: {
    seqs: ReadonlyMap<string, number>;
    send: (rowId: string, throughSeq: number, text: string) => Promise<boolean>;
  };
  /// A prompt's versions (cx-ncc.61): the prompts an edit replaced or made, each with its sibling chats,
  /// and the open that shows one of them in this pane.
  branches?: {
    of: ReadonlyMap<string, MessageBranch>;
    open: (sessionId: string) => void;
  };
  /// The image `id` a prompt of this chat sent (its `images`), as a data URL; undefined when acpmux
  /// has none.
  promptImage?: (id: string) => Promise<string | undefined>;
  /// Send a turn's prompt again (the last turn's Retry), preserving its attachments.
  retry?: (rowId: string, prompt: string) => void;
  /// Retry with another model (cx-ncc.62): the chat harness's models, the one it runs, and the retry
  /// that moves the chat to the model picked and sends the prompt again there.
  retryWith?: {
    models: readonly { id: string; name: string }[];
    current?: string;
    retry: (rowId: string, prompt: string, model: string) => void;
  };
  /// Re-run the current harness's declared login command after an authentication failure.
  reauthenticate?: () => void;
  /// Who serves this chat's turns, for failure copy (cx-w10a): the harness profile's display name and id.
  route?: { name?: string; harness?: string };
  /// Opens the model and harness picker (a failure's "Switch model" action).
  switchModel?: () => void;
  /// The changes view's hunk decisions; a card's Undo asks for its turn's hunks through it, so
  /// the view shows them as requested too.
  review?: HunkReview;
};

export const TurnActionsContext = createContext<TurnActions>({});

/// The command that signs the chat's harness in, for Sign in again: its profile's `auth.login`, else
/// the one acpmux's health check names (a CLI found on PATH has no profile, cx-gz0dz).
export function chatLoginCommand(
  catalog: AcpmuxSnapshot["catalog"],
  harness: string | undefined,
  health: HarnessHealth | undefined,
): string | undefined {
  const profile = catalog.find((entry) => entry.id === (harness ?? ""))?.auth?.login;
  const checked = health && health.id === harness ? health.login?.trim() : undefined;
  return profile || checked || undefined;
}
