// The message composer: the agent pane's prompt editor (Markdown, Shift-Enter for a new line,
// Enter sends). The text clears on send; the owner's event shows the message.
import { useRef, useState } from "react";
import { PromptEditor, type PromptEditorHandle } from "../../agent-session/acpmux/composer/PromptEditor";

export interface ComposerProps {
  placeholder: string;
  label: string;
  disabled?: boolean;
  /** Resolves true when the owner took the message; the text clears only then. */
  onSend(text: string): Promise<boolean>;
  /** Lets the page focus the field from a key (Escape from the thread, the switcher). */
  editorRef?: React.RefObject<PromptEditorHandle | null>;
  /** The starting text (an edit of an existing message). */
  initialValue?: string;
  /** Escape in the field (an inline edit cancels); the page's own Escape does not run. */
  onCancel?(): void;
  className?: string;
}

export function Composer({
  placeholder,
  label,
  disabled,
  onSend,
  editorRef,
  initialValue = "",
  onCancel,
  className,
}: ComposerProps) {
  const [value, setValue] = useState(initialValue);
  const local = useRef<PromptEditorHandle | null>(null);
  const ref = editorRef ?? local;
  const submit = (markdown: string) => {
    if (disabled || !markdown.trim()) return;
    void onSend(markdown).then((sent) => {
      if (sent) setValue((current) => (current === markdown ? "" : current));
    });
  };
  return (
    <div className={`hc-composer${disabled ? " disabled" : ""}${className ? ` ${className}` : ""}`}>
      <PromptEditor
        ref={ref}
        value={value}
        onChange={(markdown) => setValue(markdown)}
        onKeyDown={(event) => {
          if (event.key !== "Escape" || !onCancel) return;
          event.preventDefault();
          onCancel();
        }}
        onSubmit={(markdown, { cmd }) => (cmd ? undefined : submit(markdown))}
        placeholder={placeholder}
        attributes={{ "aria-label": label }}
        features={{ multiline: true }}
        className="hc-composer-field"
      />
    </div>
  );
}
