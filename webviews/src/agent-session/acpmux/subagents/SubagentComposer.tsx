// A subagent's own pane ends in a composer for that subagent (Leo, 2026-11-03: "currently it says
// "read only" on the subagents in cmux-next. we should improve that"). The subagent has no acpmux
// session of its own, so what is typed here goes to the chat it belongs to as a relay its agent
// passes on (subagentMessage.ts); the placeholder names the subagent and the line under the box
// names the chat, so a prompt never goes anywhere the composer does not say. It is the one composer
// box (ComposerBox.tsx) with the prompt and Send only: the chat's queue, pull request bar, model and
// mode chips are the chat's, and drawing them here sent edits to the chat (Leo 2026-10-20).
import { useEffect, useRef, useState } from "react";
import { inlineToken, type ComposerAttachment } from "../attachments";
import { useT } from "../i18n";
import { ComposerBox } from "../ComposerBox";
import { ArrowUpIcon } from "../ComposerPickers";

export type Draft = { text: string; attachments: ComposerAttachment[] };

/// Each subagent's unsent prompt, by `draftKey` (its chat and the subagent): opening the chat
/// ("Subagent of") unmounts the composer, and coming back finds the draft where it was left. It
/// lives as long as the page, as the chat composer's in-memory draft does.
const drafts = new Map<string, Draft>();

/// The drafts kept, for tests.
export const subagentDraftsForTests = drafts;

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
  const [text, setTextState] = useState(() => drafts.get(draftKey)?.text ?? "");
  const [failed, setFailed] = useState<string>();
  // A huge paste is a Pasted text chip (composer/pastedChips.ts); its text goes with the message, in
  // its place, since the relay is text only.
  const [attachments, setAttachmentsState] = useState<ComposerAttachment[]>(
    () => drafts.get(draftKey)?.attachments ?? [],
  );
  const attachmentsRef = useRef(attachments);
  attachmentsRef.current = attachments;
  const textRef = useRef(text);
  textRef.current = text;
  // A send that fails after the composer is gone (the person opened the chat or another subagent)
  // comes back in the kept draft, so the pane shows it when it opens again.
  const mounted = useRef(true);
  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
    };
  }, []);
  // Every change is the draft kept for this subagent (an empty one is forgotten).
  const keep = (next: Draft) => {
    if (next.text || next.attachments.length > 0) drafts.set(draftKey, next);
    else drafts.delete(draftKey);
  };
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
  const draft = () => {
    let message = text;
    const loose: string[] = [];
    for (const chip of attachmentsRef.current) {
      const pasted = chip.kind === "pasted" ? (chip.text ?? "") : "";
      const token = inlineToken(chip.id);
      if (message.includes(token)) message = message.split(token).join(pasted);
      else if (pasted) loose.push(pasted);
    }
    return [message, ...loose]
      .filter((part) => part.trim())
      .join("\n\n")
      .trim();
  };
  const ready = Boolean(onSend) && (text.trim().length > 0 || attachments.length > 0);
  const submit = () => {
    const message = draft();
    if (!onSend || !message) return;
    const typed = text;
    const held = attachmentsRef.current;
    setText("");
    setAttachments([]);
    setFailed(undefined);
    onSend(message).catch(() => {
      // The message comes back to the prompt whole (afterFailedSend).
      if (!mounted.current) {
        keep(afterFailedSend(drafts.get(draftKey) ?? { text: "", attachments: [] }, { typed, held, message }));
        return;
      }
      const next = afterFailedSend(
        { text: textRef.current, attachments: attachmentsRef.current },
        { typed, held, message },
      );
      setText(next.text);
      setAttachments(next.attachments);
      setFailed(t("subagents.messageFailed"));
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
          attributes: { role: "textbox", "aria-label": t("subagents.messagePlaceholder", { name: subagent }) },
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
