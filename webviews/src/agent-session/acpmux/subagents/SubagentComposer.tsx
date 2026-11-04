// A subagent's own pane ends in a composer for that subagent (Leo, 2026-11-03: "currently it says
// "read only" on the subagents in cmux-next. we should improve that"). The subagent has no acpmux
// session of its own, so what is typed here goes to the chat it belongs to as a relay its agent
// passes on (subagentMessage.ts); the placeholder names the subagent and the line under the box
// names the chat, so a prompt never goes anywhere the composer does not say. It is the one composer
// box (ComposerBox.tsx) with the prompt and Send only: the chat's queue, pull request bar, model and
// mode chips are the chat's, and drawing them here sent edits to the chat (Leo 2026-10-20).
import { useEffect, useRef, useState } from "react";
import type { ComposerAttachment } from "../attachments";
import { useT } from "../i18n";
import { ComposerBox } from "../ComposerBox";
import { ArrowUpIcon } from "../ComposerPickers";
import {
  draftMessage,
  keepSubagentDraft,
  restoreSubagentDraft,
  sendingSubagentDraft,
  subagentDraft,
  subscribeSubagentDraft,
  type Draft,
} from "./subagentDrafts";

/// The prompt after a send failed: the failed message comes back whole, never dropped and never
/// mixed with what was typed since (a timed-out send leaves no failed row in the chat to recover it
/// from). Into an empty prompt it comes back as it was typed, chips and all; over a newer draft, its
/// whole text (pasted chips in their places, `message`) goes above that draft, whose own chips stay
/// its own.
export function afterFailedSend(
  current: Draft,
  sent: { typed: string; held: ComposerAttachment[]; message: string },
): Draft {
  if (!current.text && current.attachments.length === 0) return { text: sent.typed, attachments: sent.held };
  return { text: `${sent.message}\n\n${current.text}`, attachments: current.attachments };
}

export function SubagentComposer({
  subagent,
  chat,
  draftKey,
  onSend,
}: {
  /// The subagent the prompt is for, as the pane names it.
  subagent: string;
  /// The chat that takes the prompt and passes it on.
  chat: string;
  /// Which draft is this subagent's (its chat and the subagent's id or name); the caller keys the
  /// composer by it, so another subagent's pane starts from its own draft.
  draftKey: string;
  /// Sends the typed message; unset while the chat takes no prompts (not connected, View Only).
  /// It resolves when the chat kept a refused message itself (its failed row), never put back here.
  onSend?: (message: string) => Promise<unknown>;
}) {
  const t = useT();
  // The kept draft (subagentDrafts.ts): opening the chat ("Subagent of") or another subagent
  // unmounts this, and coming back, or a page let go, reloaded or quit meanwhile, finds it.
  const [text, setTextState] = useState(() => subagentDraft(draftKey).text);
  const [failed, setFailed] = useState<string>();
  // A huge paste is a Pasted text chip (composer/pastedChips.ts); its text goes with the message, in
  // its place, since the relay is text only.
  const [attachments, setAttachmentsState] = useState<ComposerAttachment[]>(() => subagentDraft(draftKey).attachments);
  const attachmentsRef = useRef(attachments);
  attachmentsRef.current = attachments;
  const textRef = useRef(text);
  textRef.current = text;
  // A failed send comes back into the kept draft and to whichever composer shows this subagent
  // then: this one, or one opened again after this was gone (the person opened the chat or another
  // subagent meanwhile).
  useEffect(
    () =>
      subscribeSubagentDraft(draftKey, (restored) => {
        textRef.current = restored.text;
        attachmentsRef.current = restored.attachments;
        setTextState(restored.text);
        setAttachmentsState(restored.attachments);
        setFailed(t("subagents.messageFailed"));
      }),
    [draftKey, t],
  );
  // Every change is the draft kept for this subagent (an empty one is forgotten).
  const keep = (next: Draft) => keepSubagentDraft(draftKey, next);
  const setText = (update: string | ((current: string) => string)) =>
    setTextState((current) => {
      const next = typeof update === "function" ? update(current) : update;
      textRef.current = next;
      keep({ text: next, attachments: attachmentsRef.current });
      return next;
    });
  const setAttachments = (update: ComposerAttachment[] | ((current: ComposerAttachment[]) => ComposerAttachment[])) =>
    setAttachmentsState((current) => {
      const next = typeof update === "function" ? update(current) : update;
      attachmentsRef.current = next;
      keep({ text: textRef.current, attachments: next });
      return next;
    });
  const draft = () => draftMessage({ text, attachments: attachmentsRef.current });
  const ready = Boolean(onSend) && (text.trim().length > 0 || attachments.length > 0);
  const submit = () => {
    const message = draft();
    if (!onSend || !message) return;
    const typed = text;
    const held = attachmentsRef.current;
    // Until the chat takes it, the message is kept as in flight, so a page closed or let go
    // meanwhile still hands it on (subagentDrafts.ts).
    const settled = sendingSubagentDraft(draftKey, message);
    setText("");
    setAttachments([]);
    setFailed(undefined);
    onSend(message).then(settled, () => {
      // The message comes back to the prompt whole (afterFailedSend), over the draft kept now.
      restoreSubagentDraft(draftKey, afterFailedSend(subagentDraft(draftKey), { typed, held, message }));
      settled();
    });
  };
  return (
    <form
      className="acpmux-composer acpmux-subagent-composer"
      data-composer-grid=""
      data-cmux-component="SubagentComposer"
      onSubmit={(event) => {
        event.preventDefault();
        submit();
      }}
    >
      {failed && (
        <p className="acpmux-composer-remote-note" role="alert">
          {failed}
        </p>
      )}
      <ComposerBox
        field={{
          className: "acpmux-composer-prompt",
          value: text,
          placeholder: t("subagents.messagePlaceholder", { name: subagent }),
          attributes: {
            role: "textbox",
            "aria-label": t("subagents.messagePlaceholder", { name: subagent }),
          },
          onChange: (markdown) => setText(markdown),
          onSubmit: () => submit(),
        }}
        attachments={attachments}
        setAttachments={(update) => setAttachments((current) => update(current))}
        attachmentsRef={attachmentsRef}
        onRemoveAttachment={(id) => setAttachments((current) => current.filter((chip) => chip.id !== id))}
        fieldMenu={[]}
        chromeItems={[]}
        trailing={
          <button
            type="submit"
            className={`acpmux-send${ready ? " acpmux-send-ready" : ""}`}
            disabled={!onSend}
            aria-label={t("subagents.messageSend", { name: subagent })}
            // tooltip-allow: names the icon-only Send and the subagent it goes to.
            title={t("subagents.messageSend", { name: subagent })}
          >
            <ArrowUpIcon />
          </button>
        }
        // The quiet row's middle names the chat that passes the message on (where the chat's own
        // composer draws its look dots).
        bottom={<span className="cv-subagent-composer-via">{t("subagents.messageVia", { name: chat })}</span>}
      />
    </form>
  );
}
