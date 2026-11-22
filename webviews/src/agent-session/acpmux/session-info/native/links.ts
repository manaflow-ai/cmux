// External Session Info links use the page's existing preview callback when one is available.
// Quick Chat has no side panel, so its native rows route a safe web URL through the same chip host
// used by transcript link cards (`browser.openIn`, browserId `cmux`).
import { callChipHost } from "../../chips/host";

export type NativeExternalUrlOpener = (url: string) => void;

/// Returns an absolute web URL the native panel may open. Credentials and non-web schemes stay out
/// of native actions even when a transcript source happened to contain them.
export function safeExternalUrl(value: string): string | undefined {
  try {
    const url = new URL(value);
    if ((url.protocol !== "http:" && url.protocol !== "https:") || !url.hostname || url.username || url.password)
      return undefined;
    return url.toString();
  } catch {
    return undefined;
  }
}

/// Keeps the existing preview action when supplied; otherwise opens the URL in cmux's browser via
/// the established chip host route. The host owns gesture and outside-app policy.
export function nativeExternalUrl(onOpenUrl?: NativeExternalUrlOpener): NativeExternalUrlOpener {
  return (value) => {
    const url = safeExternalUrl(value);
    if (!url) return;
    if (onOpenUrl) {
      onOpenUrl(value);
      return;
    }
    void callChipHost("browser.openIn", { url, browserId: "cmux" });
  };
}
