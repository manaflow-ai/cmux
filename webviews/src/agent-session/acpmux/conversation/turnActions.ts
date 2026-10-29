// Actions a turn's footer and edited-files card offer that reach past the transcript (to the
// client). A context, so a change in what acpmux serves, or in what the reader decided about a
// turn's hunks, reaches memoized rows without changing their versions.
import { createContext } from "react";
import type { HunkReview } from "../changes/hunkReview";
import type { ChatAccount } from "../chatAccounts";
import type { HarnessHealth } from "../HarnessHealthNotice";
import type { AcpmuxRow, AcpmuxSnapshot } from "../model";
import type { Subagent } from "../subagents/subagentFold";
import type { MessageBranch } from "./branches";
import type { RetryModel } from "./retryModelSections";
import type { QueuedMessageActionsValue } from "./QueuedMessageCard";

export type TurnActions = {
  /// Fork the session through the turn whose summary event is `throughSeq`; absent when
  /// acpmux does not serve forks.
  fork?: (throughSeq: number) => void;
  /// The latest completed turn (`latestForkSeq`), the only one `fork` goes through unless `forkAny`.
  forkSeq?: number;
  /// Each answered prompt's own turn (`promptTurns`): the Fork under its bubble forks through it.
  promptTurns?: ReadonlyMap<string, number>;
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
    running?: ReadonlySet<string>;
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
    /// `release`: the release an alias runs, when the harness named it (retryModelSections.ts).
    models: readonly RetryModel[];
    current?: string;
    /// The harness's name and its curated top models (topModels/): the menu lists models in the
    /// composer picker's order, the rest under More models.
    harness?: string;
    top?: readonly string[];
    retry: (rowId: string, prompt: string, model: string) => void;
  };
  /// Continue a turn the reader stopped (the last turn's footer, when `resumable`): sends
  /// `CONTINUE_PROMPT` through the composer's send path, so it queues and shows as a prompt.
  resume?: () => Promise<void>;
  /// Restart on a subagent's end line (subagents/restart.ts): asks the chat to run it again with
  /// its prompt.
  restartSubagent?: (agent: Subagent) => void;
  /// Re-run the current harness's declared login command after an authentication failure.
  reauthenticate?: () => void;
  /// Explicitly set up this Cloud chat's provider credentials on its machine, then retry the turn.
  transferCloudCredentials?: (rowId: string, prompt: string) => Promise<void>;
  /// Who serves this chat's turns, for failure copy (cx-w10a): the harness profile's display name and id.
  route?: { name?: string; harness?: string; hostKind?: "local" | "cloud"; host?: string };
  /// Opens the model and harness picker (a failure's "Switch model" action).
  switchModel?: () => void;
  /// cmux's own route for a key, sign-in or capacity failure (CodeRouterOffer.tsx): what the chat's
  /// routes offer of CodeRouter (chatAccounts.ts codeRouterOffer), and the move onto a route, which
  /// acpmux applies at once on an idle chat and resumes the same session. Only on this Mac's acpmux.
  ownRoute?: {
    find: () => Promise<ChatAccount | "on" | undefined>;
    use: (routeId: string) => Promise<void>;
  };
  /// What another agent's waiting message's ⋯ menu does (conversation/QueuedMessageCard.tsx), as
  /// the chat offers it now; undefined while the chat is not connected.
  queuedMessages?: () => QueuedMessageActionsValue | undefined;
  /// The X beside a steer the agent has not read yet: takes it back into the composer to edit
  /// (PendingSteer.tsx `takeBackSteer`); false when the agent read it first.
  unsteer?: (row: AcpmuxRow) => Promise<boolean>;
  /// The changes view's hunk decisions; a card's Undo asks for its turn's hunks through it, so
  /// the view shows them as requested too.
  review?: HunkReview;
};

export const TurnActionsContext = createContext<TurnActions>({});

/// The prompt Continue sends after a stopped turn. Claude Code and Codex both resume on a plain
/// "continue"; it goes to the agent, never shown as UI. l10n-allow: a prompt to the agent, not UI
export const CONTINUE_PROMPT = "Continue";

/// The footer's Continue: `CONTINUE_PROMPT` through the composer's send (`chat.send`), so it shows as
/// the reader's prompt and starts the next turn, or queues behind a prompt already sent. A send that
/// fails says so on its own row. Settles once the send does (when that turn ends, or it failed).
export const resumeThrough =
  (callNative: (method: string, params: Record<string, unknown>) => Promise<unknown>) => (): Promise<void> =>
    callNative("chat.send", { text: CONTINUE_PROMPT }).then(() => undefined);

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
