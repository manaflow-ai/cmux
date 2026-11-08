// Save as Prompt, in a message's hover row (MessageActions.tsx): a small popover asks for a name
// (the message's first words to start), and Save keeps the message as a saved prompt
// (savedPrompts.ts), which `/name` then writes into any chat's composer. The popover says where to
// find it and closes; a refusal (acpmux's sentence) stays in it with the name kept.
import { useEffect, useId, useRef, useState } from "react";
import { Button } from "../../../ui/Button";
import { Popover } from "../../../ui/Popover";
import { useT } from "../i18n";
import { PROMPT_NAME_MAX, promptSlug, savePrompt, suggestedName } from "../savedPrompts";
import { useTranscriptReadOnly } from "./readOnly";
import { ROW_ICON } from "./messageActionsModel";
import "./savePrompt.css";

/// How long the popover says the prompt was saved before it closes.
const SAVED_SHOWN_MS = 1400;

export function SavePromptButton({ text }: { text: string }) {
  const t = useT();
  const readOnly = useTranscriptReadOnly();
  const button = useRef<HTMLButtonElement>(null);
  const input = useRef<HTMLInputElement>(null);
  const [open, setOpen] = useState(false);
  const [name, setName] = useState("");
  const [state, setState] = useState<{ kind: "idle" | "saving" | "saved" } | { kind: "failed"; message: string }>({
    kind: "idle",
  });
  const errorId = useId();
  // The saved line shows a moment, then the popover closes; closing or unmounting ends the wait.
  useEffect(() => {
    if (state.kind !== "saved" || !open) return;
    const timer = setTimeout(() => setOpen(false), SAVED_SHOWN_MS);
    return () => clearTimeout(timer);
  }, [state.kind, open]);
  if (readOnly || !text.trim()) return null;
  const label = t("message.savePrompt");
  const slug = promptSlug(name);
  const save = () => {
    if (!slug || state.kind === "saving") return;
    setState({ kind: "saving" });
    savePrompt(name, text).then(
      () => setState({ kind: "saved" }),
      (error: unknown) =>
        setState({ kind: "failed", message: error instanceof Error ? error.message : t("message.savePromptFailed") }),
    );
  };
  return (
    <>
      <button
        ref={button}
        type="button"
        className="cv-iconbtn cv-iconbtn--compact cv-save-prompt"
        aria-haspopup="dialog"
        aria-expanded={open}
        aria-label={label}
        title={label}
        onClick={() => {
          setName(suggestedName(text));
          setState({ kind: "idle" });
          setOpen(true);
        }}
      >
        <SavePromptGlyph />
      </button>
      <Popover
        open={open}
        onOpenChange={setOpen}
        anchor={button.current}
        label={label}
        className="cv-save-prompt-popover"
        side="top"
        initialFocus={input}
        finalFocus={button}
      >
        <form
          className="cv-save-prompt-form"
          onSubmit={(event) => {
            event.preventDefault();
            save();
          }}
        >
          <label className="cv-save-prompt-label">
            <span>{t("message.savePromptName")}</span>
            <input
              ref={input}
              className="cv-save-prompt-input"
              value={name}
              maxLength={PROMPT_NAME_MAX}
              spellCheck={false}
              aria-invalid={state.kind === "failed" || undefined}
              aria-describedby={state.kind === "failed" ? errorId : undefined}
              onChange={(event) => {
                setName(event.currentTarget.value);
                if (state.kind !== "saving") setState({ kind: "idle" });
              }}
              onFocus={(event) => event.currentTarget.select()}
            />
          </label>
          <p className="cv-save-prompt-note" id={errorId} data-tone={state.kind === "failed" ? "error" : undefined}>
            {state.kind === "failed"
              ? state.message
              : state.kind === "saved"
                ? t("message.savePromptSaved", { name: slug })
                : slug
                  ? t("message.savePromptHint", { name: slug })
                  : " "}
          </p>
          <div className="cv-save-prompt-actions">
            <Button type="button" variant="ghost" size="sm" onClick={() => setOpen(false)}>
              {t("message.savePromptCancel")}
            </Button>
            <Button
              type="submit"
              variant="solid"
              size="sm"
              disabled={!slug || state.kind === "saving" || state.kind === "saved"}
            >
              {t("message.savePromptSave")}
            </Button>
          </div>
        </form>
      </Popover>
    </>
  );
}

/// A page with a plus at its corner: keep this as a prompt.
function SavePromptGlyph() {
  return (
    <svg width={ROW_ICON} height={ROW_ICON} viewBox="0 0 16 16" aria-hidden="true">
      <path
        d="M9 2.5H4.5a1 1 0 0 0-1 1v9a1 1 0 0 0 1 1h7a1 1 0 0 0 1-1V8M5.75 7.5h3M5.75 10h4.5M12 1.75v4M10 3.75h4"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.25"
        strokeLinecap="round"
      />
    </svg>
  );
}
