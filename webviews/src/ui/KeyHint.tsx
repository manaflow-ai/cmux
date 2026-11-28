import type { HTMLAttributes } from "react";
import { KEY_HINT_CLASS, keyHintParts, keyHintSource, type KeyHintKeys } from "./keyHintModel";

export { keyHintElement, keyHintParts, keyHintStrokes, type KeyHintKeys } from "./keyHintModel";

export interface KeyHintProps extends Omit<HTMLAttributes<HTMLElement>, "children"> {
  /** "⌃⌘M", "⌘↩", "Esc", or native's keycaps array (["⌘", "J", "S"] draws ⌘J then S). */
  keys: KeyHintKeys;
}

/** A keyboard shortcut, drawn the one way the web UI draws one (ui/keyHintModel.ts says how and why). A host
 * passes `className` only to place it (a tooltip floats it to the end, a menu row pushes it right). */
export function KeyHint({ keys, className, ...rest }: KeyHintProps) {
  return (
    <kbd
      {...rest}
      className={className ? `${KEY_HINT_CLASS} ${className}` : KEY_HINT_CLASS}
      data-keys={keyHintSource(keys)}
    >
      {keyHintParts(keys).map((part, index) =>
        part.kind === "then" ? (
          <span key={index} className="ui-key-hint-then">
            {part.text}
          </span>
        ) : (
          <span key={index} className="ui-key-hint-key" data-word={part.word ? "" : undefined}>
            {part.text}
          </span>
        ),
      )}
    </kbd>
  );
}
