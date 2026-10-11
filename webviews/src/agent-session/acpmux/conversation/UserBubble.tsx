// A prompt's bubble, with Copy and Edit under it (cx-ncc.60, Claude parity). Edit opens the prompt in
// place; Send forks the chat through the turn before it and sends the edited text there (the App's
// `edit.send`), Escape or Cancel puts the bubble back. Edit shows only on a prompt the chat can fork
// before (`editableTurns`), so it is never dead.
import { useContext, useLayoutEffect, useRef, useState } from "react";
import type { AcpmuxRow } from "../model";
import { useT } from "../i18n";
import { copyText } from "./clipboard";
import { Copy, Pencil } from "./icons";
import { TurnActionsContext } from "./turnActions";

export function UserBubble({ row, text }: { row: AcpmuxRow; text: string }) {
  const t = useT();
  const { edit } = useContext(TurnActionsContext);
  const [editing, setEditing] = useState(false);
  const [copied, setCopied] = useState(false);
  const through = edit?.seqs.get(row.id);
  if (editing && edit && through !== undefined) {
    return (
      <PromptEditor
        initial={row.text ?? text}
        onCancel={() => setEditing(false)}
        onSend={(value) => {
          setEditing(false);
          edit.send(row.id, through, value);
        }}
      />
    );
  }
  return (
    <>
      <div className="cv-user__bubble selectable">{text}</div>
      {text && !row.failed && !row.queued && (
        <div className="cv-user__actions">
          <button
            type="button"
            className="cv-iconbtn cv-iconbtn--compact"
            aria-label={copied ? t("turn.copied") : t("turn.copy")}
            title={copied ? t("turn.copied") : t("turn.copy")}
            onClick={() =>
              void copyText(row.text ?? text).then(
                () => setCopied(true),
                () => setCopied(false),
              )
            }
          >
            <Copy size={14} />
          </button>
          {through !== undefined && (
            <button
              type="button"
              className="cv-iconbtn cv-iconbtn--compact"
              aria-label={t("message.edit")}
              title={t("message.edit")}
              onClick={() => setEditing(true)}
            >
              <Pencil size={14} />
            </button>
          )}
        </div>
      )}
    </>
  );
}

function PromptEditor({
  initial,
  onCancel,
  onSend,
}: {
  initial: string;
  onCancel(): void;
  onSend(text: string): void;
}) {
  const t = useT();
  const [value, setValue] = useState(initial);
  const field = useRef<HTMLTextAreaElement>(null);
  // Opened to type in: the caret at the end, the field as tall as the prompt.
  useLayoutEffect(() => {
    const element = field.current;
    if (!element) return;
    element.focus();
    element.setSelectionRange(element.value.length, element.value.length);
  }, []);
  useLayoutEffect(() => {
    const element = field.current;
    if (!element) return;
    element.style.height = "auto";
    element.style.height = `${element.scrollHeight}px`;
  }, [value]);
  const send = () => {
    if (value.trim()) onSend(value);
  };
  return (
    <div className="cv-user__edit">
      <textarea
        ref={field}
        className="cv-user__edit-field selectable"
        aria-label={t("message.editLabel")}
        value={value}
        rows={1}
        onChange={(event) => setValue(event.target.value)}
        // ui-allow: the editor's own Enter (send) and Escape (cancel), as the composer's
        onKeyDown={(event) => {
          if (event.nativeEvent.isComposing) return;
          if (event.key === "Escape") {
            event.preventDefault();
            onCancel();
          } else if (event.key === "Enter" && !event.shiftKey) {
            event.preventDefault();
            send();
          }
        }}
      />
      <div className="cv-user__edit-actions">
        <button type="button" className="cv-user__edit-button" onClick={onCancel}>
          {t("message.editCancel")}
        </button>
        <button
          type="button"
          className="cv-user__edit-button cv-user__edit-button--send"
          aria-label={t("message.editSend")}
          disabled={!value.trim()}
          onClick={send}
        >
          {t("message.editSend")}
        </button>
      </div>
    </div>
  );
}
