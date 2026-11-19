// A subagent's own pane ends in a composer for that subagent (Leo, 2026-11-03: "currently it says
// "read only" on the subagents in cmux-next. we should improve that"). The subagent has no acpmux
// session of its own, so what is typed here goes to the chat it belongs to as a relay its agent
// passes on (subagentMessage.ts); the quiet row under the box names the chat, so a prompt never goes
// anywhere the composer does not say. It is the chat's composer box (ComposerBox.tsx) with the chat
// composer's own slots and rules (Leo, 2026-11-19: "the composer is kinda odd looking for
// subagents"): + on the left, the mic and Send on the right, Send's glyph and its at-rest rule from
// the composer look, and the quiet row under it. + is drawn disabled, since the relay carries text
// only; the chat's queue, pull request bar, model and mode chips stay the chat's, and drawing them
// here sent edits to the chat (Leo 2026-10-20). The quiet row holds the routing note where the
// chat's composer holds its mode, so both composers stand the same height and switching the pane
// between the chat and a subagent moves nothing (Leo, 2026-11-19: "and it layout shifts too").
import React, { useEffect, useRef, useState } from "react";
import type { ComposerAttachment } from "../attachments";
import { useT } from "../i18n";
import { ComposerBox } from "../ComposerBox";
import type { MarkdownFieldHandle } from "../MarkdownField";
import { PlusIcon } from "../ComposerPickers";
import { SendSlotGlyph } from "../composer/SendSlotGlyph";
import { useComposerChrome } from "../composerChromeModel";
import { useComposerLook } from "../composerLook";
import { useComposerSettings } from "../composerSettings";
import { isActive, type Dictation } from "../dictation";
import { DictationStrip } from "../DictationListening";
import { experimentArm } from "../../../experiments/experiment";
import { subagentComposerVia } from "./subagentComposerVia.experiment";
import {
  draftMessage,
  keepSubagentDraft,
  restoreSubagentDraft,
  sendingSubagentDraft,
  subagentDraft,
  subscribeSubagentDraft,
  type Draft,
} from "./subagentDrafts";
import { afterFailedSend } from "./subagentComposerModel";
export function SubagentComposer({
  subagent,
  chat,
  draftKey,
  onSend,
  quoteRef,
  accessory,
  dictation,
  promptRef,
}: {
  /// The subagent the prompt is for, as the pane names it (the prompt's accessible name and Send's).
  subagent: string;
  /// The chat that takes the prompt and passes it on.
  chat: string;
  /// Which draft is this subagent's (its chat and the subagent's id or name); the caller keys the
  /// composer by it, so another subagent's pane starts from its own draft.
  draftKey: string;
  /// Sends the typed message; unset while the chat takes no prompts (not connected, View Only).
  /// It resolves when the chat kept a refused message itself (its failed row), never put back here.
  onSend?: (message: string) => Promise<unknown>;
  /// Quote in Reply's target while this composer shows (App.tsx `chat.quoteReply`): the quote goes
  /// after this subagent's draft, as the chat's composer puts it after its own.
  quoteRef?: { current: { quoteReply(markdown: string): void } | null };
  /// The pane's dictation mic (DictationMic.tsx), in the slot the chat's composer draws it in; its
  /// words land in this prompt (`promptRef`), and Send ends a running session first, as there.
  accessory?: React.ReactNode;
  dictation?: Dictation;
  /// Also receives the prompt field's handle, for dictation, which writes into it as typing does.
  promptRef?: { current: MarkdownFieldHandle | null };
}) {
  const t = useT();
  // The chat composer's look decides Send's glyph and whether it shows at rest (Composer.tsx
  // `quietActions`): Claude's draws ↵ before the mic only with a draft, Codex's its ↑ after the mic.
  const { plainFooter } = useComposerSettings();
  const look = useComposerLook();
  const quietActions = plainFooter && look !== "codex";
  const chrome = useComposerChrome();
  const [viaPlace] = useState(() => experimentArm(subagentComposerVia));
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
  const field = useRef<MarkdownFieldHandle | null>(null);
  useEffect(() => {
    if (!quoteRef) return;
    const handle = {
      quoteReply(markdown: string) {
        if (field.current?.quoteReply(markdown)) return;
        setText((typed) => (typed ? `${typed}\n\n${markdown}` : markdown));
        field.current?.focus();
      },
    };
    quoteRef.current = handle;
    return () => {
      if (quoteRef.current === handle) quoteRef.current = null;
    };
    // oxlint-disable-next-line react-hooks/exhaustive-deps -- setText reads refs; the handle lives as long as this composer
  }, [quoteRef]);
  // The prompt as it is now: dictation writes into the field, and its last words land just before
  // the send that ended it runs.
  const typedNow = () => field.current?.value() ?? textRef.current;
  const draft = () => draftMessage({ text: typedNow(), attachments: attachmentsRef.current });
  const listening = dictation !== undefined && isActive(dictation.state);
  /// Set while the send a finished dictation session waited for goes.
  const dictationEnded = useRef(false);
  const ready = Boolean(onSend) && (text.trim().length > 0 || attachments.length > 0);
  const submit = () => {
    // A dictation session still running ends first, keeping its words, and the send goes once they
    // are in the prompt (dictation.ts finish), as the chat's composer does.
    if (dictation && isActive(dictation.state) && !dictationEnded.current) {
      dictation.finish(() => {
        // The session is over even if this render has not heard so yet.
        dictationEnded.current = true;
        try {
          submit();
        } finally {
          dictationEnded.current = false;
        }
      });
      return;
    }
    const message = draft();
    if (!onSend || !message) return;
    const typed = typedNow();
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
  const sendLabel = t("subagents.messageSend", { name: subagent });
  // One send control, in the chat composer's slot: before the mic in Claude's look (only with a
  // draft or while dictating), last in Codex's.
  const send =
    onSend && (!quietActions || ready || listening) ? (
      <button
        type="submit"
        className={`acpmux-send${ready ? " acpmux-send-ready" : ""}`}
        aria-label={sendLabel}
        // tooltip-allow: names the icon-only Send and the subagent it goes to.
        title={sendLabel}
      >
        <SendSlotGlyph glyph={quietActions ? "return" : "arrow"} />
      </button>
    ) : null;
  const viaText = t("subagents.messageVia", { name: chat });
  // The routing note in the quiet row, where the chat's composer names its mode: the same row,
  // height and ink, so it is part of the composer, never a caption floating under it.
  const via =
    viaPlace === "caption" ? undefined : (
      <span className="acpmux-chips">
        <span
          className="acpmux-subagent-via"
          data-via-place={viaPlace}
          // tooltip-allow: the chip arm shows only the chat's name; the sentence says what it does.
          title={viaPlace === "chip" ? viaText : undefined}
        >
          {viaPlace === "chip" && <RouteIcon />}
          <span className="acpmux-subagent-via-text">{viaPlace === "chip" ? chat : viaText}</span>
        </span>
      </span>
    );
  return (
    <form
      className="acpmux-composer acpmux-subagent-composer"
      data-composer-look={look === "codex" ? "codex" : undefined}
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
          // Short, as the chat's own is: the pill over the transcript names the task.
          placeholder: listening ? t("dictation.listening") : t("subagents.messagePlaceholderShort"),
          attributes: {
            role: "textbox",
            "aria-label": t("subagents.messagePlaceholder", { name: subagent }),
          },
          onChange: (markdown) => setText(markdown),
          // A quote taken while the editor was still being made, when this composer goes first: it
          // stays this subagent's, after its kept draft, for the next composer that shows it.
          onUnplacedQuotes: (quotes) => {
            const kept = subagentDraft(draftKey);
            keep({ ...kept, text: [kept.text, ...quotes].filter(Boolean).join("\n\n") });
          },
          onSubmit: () => submit(),
        }}
        fieldRef={(handle) => {
          field.current = handle;
          if (promptRef) promptRef.current = handle;
        }}
        attachments={attachments}
        setAttachments={(update) => setAttachments((current) => update(current))}
        attachmentsRef={attachmentsRef}
        onRemoveAttachment={(id) => setAttachments((current) => current.filter((chip) => chip.id !== id))}
        fieldMenu={[]}
        // + keeps the chat composer's slot and glyph, disabled: the relay to a subagent is text only.
        leading={
          <span className="acpmux-picker acpmux-composer-plus">
            <button
              type="button"
              className="acpmux-picker-button"
              disabled
              aria-label={t("composer.add")}
              // tooltip-allow: says why + does nothing here.
              title={t("subagents.addUnavailable")}
            >
              <PlusIcon />
            </button>
          </span>
        }
        chips={via}
        actionsLead={
          <>
            {dictation && <DictationStrip dictation={dictation} shown={listening} />}
            {quietActions && send}
          </>
        }
        {...(accessory ? { accessory } : {})}
        trailing={quietActions ? undefined : send}
        chromeItems={[chrome.dictation]}
      />
      {viaPlace === "caption" && <p className="cv-subagent-composer-via">{viaText}</p>}
    </form>
  );
}

/// The chip arm's route mark: a message passing through a stop on its way.
function RouteIcon() {
  return (
    <svg className="acpmux-subagent-via-icon" viewBox="0 0 16 16" width="14" height="14" aria-hidden="true">
      <path
        d="M3 3.5h5.5a2.5 2.5 0 0 1 0 5h-2a2.5 2.5 0 0 0 0 5H13m-2-2 2 2-2 2"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.3"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  );
}
