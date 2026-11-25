// New Message as a page, as in Messages (HomeNewMessageView): the To: field across the top, and
// under it either the conversation the chosen people already have (its history, its own message
// box) or a blank page with Home's message box. The first send there makes the DM or group and
// posts the text (`ComposeActions.start`, HomeService.startConversation); the page then shows the
// conversation (`onSent`). A refusal says why under the field and keeps the text in the box. The
// list under the field floats over the content, so choosing people never moves the page.
// The conversation and the message box are the transcript's (render props); the draft is the
// page's, so it stays while the person looks at another conversation.
import { useMemo, useState, type ReactNode } from "react";
import type { Strings } from "../../shared/i18n";
import type { ComposeActions } from "./actions";
import { composeCloses, composeMessage } from "./model";
import {
  draftRecipients,
  existingConversation,
  idleSuggestions,
  sendBlocker,
  type ExistingConversationRow,
  type HomeContact,
  type HomeRecipient,
  type RecipientDraft,
  type RecipientLook,
} from "./recipients";
import { RecipientField, type TokenStyle } from "./RecipientField";

export interface NewMessageProps {
  strings: Strings;
  draft: RecipientDraft;
  onDraft(draft: RecipientDraft): void;
  contacts: readonly HomeContact[];
  /** The page's conversations, for the one the chosen people already have. */
  rows: readonly ExistingConversationRow[];
  me?: string;
  actions: ComposeActions;
  /** The active team's name (an "Invite … to <team>" row under a typed address); null: none. */
  inviteTeam?: string | null;
  look?(recipient: HomeRecipient): RecipientLook;
  /** The first send made this conversation: the page shows it. */
  onSent(conversation: string): void;
  /** Escape with nothing chosen or typed: the page may end the draft (if its message box is empty). */
  onEscape(): void;
  /** Return or Tab with nothing typed in To:: the message box takes the keyboard. */
  onFocusMessage(): void;
  /** The chosen people's conversation, under the field. */
  renderConversation(conversation: string): ReactNode;
  /** The blank page's message box; `send` makes the conversation and resolves whether it went. */
  renderComposer(send: (text: string) => Promise<boolean>): ReactNode;
  tokenStyle?: TokenStyle;
  /** A refusal to show at first (the gallery). */
  initialNotice?: string;
}

export function NewMessage({
  strings,
  draft,
  onDraft,
  contacts,
  rows,
  me,
  actions,
  inviteTeam = null,
  look,
  onSent,
  onEscape,
  onFocusMessage,
  renderConversation,
  renderComposer,
  tokenStyle,
  initialNotice,
}: NewMessageProps) {
  const [notice, setNotice] = useState<string | null>(initialNotice ?? null);
  const existing = useMemo(() => existingConversation(draft, rows, me), [draft, rows, me]);
  const idle = useMemo(() => idleSuggestions(draft, contacts), [draft, contacts]);
  const changed = (next: RecipientDraft) => {
    setNotice(null);
    onDraft(next);
  };
  const send = async (text: string): Promise<boolean> => {
    const blocker = sendBlocker(draft, strings);
    if (blocker) {
      setNotice(blocker);
      return false;
    }
    const outcome = await actions.start(draftRecipients(draft), text);
    const close = composeCloses(outcome);
    if (close.closes) {
      if (close.conversation) onSent(close.conversation);
      return true;
    }
    setNotice(composeMessage(outcome, strings) ?? strings.t("home.compose.needsRecipient"));
    return false;
  };
  return (
    <section className="hm-new-message" aria-label={strings.t("home.compose.title")} data-testid="cmux.home.newMessage">
      <div className="hm-new-message-head">
        <RecipientField
          strings={strings}
          draft={draft}
          onDraft={changed}
          contacts={contacts}
          idle={idle}
          onNewChief={actions.newChief}
          onInvite={actions.openInvite}
          inviteTeam={inviteTeam}
          onInviteToTeam={actions.openTeamInvite}
          onDone={onFocusMessage}
          onEscape={onEscape}
          look={look}
          tokenStyle={tokenStyle}
          focusOnMount
        />
        {notice && (
          <p className="hm-new-message-notice" role="alert" data-testid="cmux.home.newMessage.notice">
            {notice}
          </p>
        )}
      </div>
      <div className="hm-new-message-body">{existing ? renderConversation(existing) : renderComposer(send)}</div>
    </section>
  );
}
