// The wire of `cmux.overlay.dialog.state` (CmuxNextPages OverlayDialogProvider): the dialog this
// overlay page draws, or none. Strings arrive localized; the page adds no words of its own.

export type DialogValue = string | boolean;

export type DialogField =
  | { kind: "text"; id: string; label?: string; placeholder?: string; secure: boolean }
  | {
      kind: "choice";
      id: string;
      label?: string;
      options: { label: string; value: string; enabled: boolean }[];
    }
  | { kind: "check"; id: string; title: string }
  | { kind: "preview"; text: string };

export type DialogButtonRole = "default" | "cancel" | "destructive" | "normal";

export interface DialogButtonSpec {
  id: string;
  title: string;
  role: DialogButtonRole;
  /** The keycap the button shows ("↩", "⎋", "⌘D"); none in the safe-default layout. */
  hint?: string;
  /** The key as VoiceOver reads it ("Command-D"). */
  hintLabel?: string;
}

/** The buttons each key presses (CmuxDialogKeys): Return, Escape and Command plus a character. */
export interface DialogKeys {
  return?: string;
  escape?: string;
  command: Record<string, string>;
}

export interface DialogState {
  id: number;
  title: string;
  /** "From example.com": the web origin that asked, above the lines. */
  from?: string;
  lines: string[];
  fields: DialogField[];
  /** Left to right as drawn. */
  buttons: DialogButtonSpec[];
  keys: DialogKeys;
  layout: "standard" | "safeDefault";
  values: Record<string, DialogValue>;
  /** Bumped by each value the host sets: the page then takes the host's values, a secure field's too. */
  valuesSerial?: number;
  icon?: string;
  identifier?: string;
  /** A key asked the focus to move: once per serial. */
  focus: { serial: number; backward: boolean } | null;
  /** How many times the dialog has shown (a tab switch hides and shows it): each new show puts the
   * focus back where the dialog opens. */
  shown?: number;
}

export interface DialogStream {
  dialog: DialogState | null;
}
