// The message composer: the agent pane's prompt editor (Markdown, Shift-Enter for a new line,
// Enter sends). The text clears on send; the owner's event shows the message.
import { useRef, useState } from "react";
import { PromptEditor, type PromptEditorHandle } from "../../agent-session/acpmux/composer/PromptEditor";

export interface ComposerProps {
  placeholder: string;
  label: string;
  disabled?: boolean;
  onSend(text: string): void;
  /** Lets the page focus the field from a key (Escape from the thread, the switcher). */
  editorRef?: React.RefObject<PromptEditorHandle | null>;
}

export function Composer({ placeholder, label, disabled, onSend, editorRef }: ComposerProps) {
  const [value, setValue] = useState("");
  const local = useRef<PromptEditorHandle | null>(null);
  const ref = editorRef ?? local;
  const submit = (markdown: string) => {
    if (disabled || !markdown.trim()) return;
    onSend(markdown);
    setValue("");
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
