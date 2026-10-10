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
}

export function Composer({ placeholder, label, disabled, onSend, editorRef }: ComposerProps) {
  const [value, setValue] = useState("");
  const local = useRef<PromptEditorHandle | null>(null);
  const ref = editorRef ?? local;
  const submit = (markdown: string) => {
    if (disabled || !markdown.trim()) return;
    void onSend(markdown).then((sent) => {
      if (sent) setValue((current) => (current === markdown ? "" : current));
    });
  };
  return (
    <div className={`hc-composer${disabled ? " disabled" : ""}`}>
      <PromptEditor
        ref={ref}
        value={value}
        onChange={(markdown) => setValue(markdown)}
        onSubmit={(markdown, { cmd }) => (cmd ? undefined : submit(markdown))}
        placeholder={placeholder}
        attributes={{ "aria-label": label }}
        features={{ multiline: true }}
        className="hc-composer-field"
      />
    </div>
  );
}
