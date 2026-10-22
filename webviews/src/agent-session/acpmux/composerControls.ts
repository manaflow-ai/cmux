// Chat controls belong to the composer's existing menus, even if the field is in `!` mode.
// Keep this shared by New Tab and an open chat: neither may turn `/fast` into a shell path.
import type { Translate } from "./i18n";
import { openPicker } from "./pickerOpeners";

export type ComposerControl = "model" | "mode";

/** The controls owned by the composer rather than sent as a prompt or executed by a shell. */
export function composerControl(text: string): ComposerControl | undefined {
  if (/^\/(?:fast|account|effort|model)\s*$/i.test(text.trim())) return "model";
  if (/^\/(?:permissions|mode)\s*$/i.test(text.trim())) return "mode";
  return undefined;
}

/** Open the same mounted control as a pointer click. The picker remains the sole state owner. */
export function openComposerControl(control: ComposerControl, t: Translate): boolean {
  return openPicker(t(control === "model" ? "picker.model" : "picker.mode"));
}
