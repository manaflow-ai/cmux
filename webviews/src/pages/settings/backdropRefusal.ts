// Why a background could not be brought in (a picked file or a link), in the page's words. The
// host judges the bytes and caps the size but words nothing: its refusal codes are worded here, for
// Choose Image and Add from a Link alike.
import { t } from "./strings";

const REFUSALS: Record<string, string> = {
  "cmux.settings.backdrop.not_https": "settingsWindow.backdropPicker.notHttps",
  "cmux.settings.backdrop.not_media": "settingsWindow.backdropPicker.notMedia",
  "cmux.settings.backdrop.too_large": "settingsWindow.backdropPicker.tooLarge",
};

/** Whether `code` is one of the host's background refusals. */
export function isBackdropRefusal(code: string | undefined): code is string {
  return !!code && code in REFUSALS;
}

/** Why a link could not be used, in the page's words; a download failure for any other code. */
export function linkRefusal(code: string): string {
  return t(REFUSALS[code] ?? "settingsWindow.backdropPicker.downloadFailed");
}
