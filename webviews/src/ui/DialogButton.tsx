// The one button of every web dialog and sheet (u2647): it shows the key that presses it, as the
// native cmux dialogs do ("Cancel ⎋", "Create ↩", "Don't Save ⌘D"), and tells assistive tech the
// same key (aria-keyshortcuts). Return and Escape are answered by the dialog itself (a form submit,
// ui/Dialog's Escape); a Command key is answered here while the button is mounted and enabled.
import { useEffect, useRef, type ButtonHTMLAttributes, type ReactNode, type Ref } from "react";
import { cx } from "./cx";

/** The key that presses a dialog button: Return, Escape, an arrow (viewers step with them), or
 * Command plus one character. */
export type DialogKey = "return" | "escape" | "left" | "right" | { command: string };

/** The keycap text, as macOS menus write keys. */
export function dialogKeyGlyph(key: DialogKey): string {
  if (key === "return") return "↩";
  if (key === "escape") return "⎋";
  if (key === "left") return "←";
  if (key === "right") return "→";
  return `⌘${key.command.toUpperCase()}`;
}

/** The key in `aria-keyshortcuts` syntax. */
export function dialogKeyAria(key: DialogKey): string {
  if (key === "return") return "Enter";
  if (key === "escape") return "Escape";
  if (key === "left") return "ArrowLeft";
  if (key === "right") return "ArrowRight";
  return `Meta+${key.command.toUpperCase()}`;
}

/** The props that name an icon-only button's key: its label for VoiceOver, the key in
 * `aria-keyshortcuts`, and a tooltip of the label and the keycap ("Close ⎋"). The dialog answers
 * the key; spread these on the button. */
export function keyedIconProps(label: string, key: DialogKey) {
  return { "aria-label": label, "aria-keyshortcuts": dialogKeyAria(key), title: `${label} ${dialogKeyGlyph(key)}` };
}

export interface DialogButtonProps extends Omit<ButtonHTMLAttributes<HTMLButtonElement>, "children"> {
  /** The key that presses it; null for a button no key presses (it shows none). */
  dialogKey: DialogKey | null;
  children: ReactNode;
  ref?: Ref<HTMLButtonElement>;
}

export function DialogButton({
  dialogKey,
  children,
  className,
  type = "button",
  ref: outer,
  ...rest
}: DialogButtonProps) {
  const ref = useRef<HTMLButtonElement | null>(null);
  const attach = (node: HTMLButtonElement | null) => {
    ref.current = node;
    if (typeof outer === "function") outer(node);
    else if (outer) outer.current = node;
  };
  const command = dialogKey && typeof dialogKey === "object" ? dialogKey.command.toLowerCase() : null;
  useEffect(() => {
    if (!command) return;
    const press = (event: KeyboardEvent) => {
      if (!event.metaKey || event.ctrlKey || event.altKey || event.key.toLowerCase() !== command) return;
      const button = ref.current;
      if (!button || button.disabled) return;
      event.preventDefault();
      event.stopPropagation();
      button.click();
    };
    document.addEventListener("keydown", press, true);
    return () => document.removeEventListener("keydown", press, true);
  }, [command]);
  return (
    <button
      {...rest}
      ref={attach}
      type={type}
      className={cx("ui-dialog-button", className)}
      aria-keyshortcuts={dialogKey ? dialogKeyAria(dialogKey) : undefined}
    >
      {children}
      {dialogKey && (
        <kbd className="ui-keyhint" aria-hidden="true">
          {dialogKeyGlyph(dialogKey)}
        </kbd>
      )}
    </button>
  );
}
