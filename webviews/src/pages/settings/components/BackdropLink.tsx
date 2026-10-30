// Add from a Link (backgrounds plan phase 3): an https image or movie downloads into the
// backgrounds folder and becomes the background, as a picked or dropped file does. The host
// judges the bytes, caps the size and words nothing; the refusal codes are worded here.
import { useState } from "react";
import { useStore } from "../context";
import { t } from "../strings";

const REFUSALS: Record<string, string> = {
  "cmux.settings.backdrop.not_https": "settingsWindow.backdropPicker.notHttps",
  "cmux.settings.backdrop.not_media": "settingsWindow.backdropPicker.notMedia",
  "cmux.settings.backdrop.too_large": "settingsWindow.backdropPicker.tooLarge",
};

/** Why a link could not be used, in the page's words. */
export function linkRefusal(code: string): string {
  return t(REFUSALS[code] ?? "settingsWindow.backdropPicker.downloadFailed");
}

export function BackdropLink({ onClose }: { onClose: () => void }) {
  const store = useStore();
  const [link, setLink] = useState("");
  const [busy, setBusy] = useState(false);
  const [refusal, setRefusal] = useState<string | null>(null);
  const add = async () => {
    const text = link.trim();
    if (!text) return;
    setBusy(true);
    setRefusal(null);
    const code = await store.addBackdropLink(text);
    setBusy(false);
    if (code === null) onClose();
    else setRefusal(linkRefusal(code));
  };
  return (
    <div className="art-browser" data-card="backdrop-link">
      <form
        className="art-browser-search"
        onSubmit={(event) => {
          event.preventDefault();
          void add();
        }}
      >
        <input
          className="field"
          type="url"
          aria-label={t("settingsWindow.backdropPicker.linkField")}
          placeholder={t("settingsWindow.backdropPicker.linkField")}
          value={link}
          onChange={(event) => setLink(event.target.value)}
        />
        <button type="submit" className="button" disabled={busy || !link.trim()}>
          {t("settingsWindow.backdropPicker.add")}
        </button>
        <button type="button" className="button" onClick={onClose}>
          {t("settingsWindow.artBrowser.close")}
        </button>
      </form>
      <output className="row-help">{busy ? t("settingsWindow.artBrowser.downloading") : refusal}</output>
    </div>
  );
}

/** Bytes as the person reads them: megabytes, or gigabytes past a thousand of them. */
export function formatBytes(bytes: number, locale?: string): string {
  const giga = bytes >= 1e9;
  return new Intl.NumberFormat(locale, {
    style: "unit",
    unit: giga ? "gigabyte" : "megabyte",
    maximumFractionDigits: 1,
  }).format(giga ? bytes / 1e9 : bytes / 1e6);
}
