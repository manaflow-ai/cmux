// The Image and SVG tabs: choose a file, drop one, paste one, or give a URL. Raster images are
// scaled down in the page to at most MAX_IMAGE_SIDE pixels (an icon never draws larger), so the
// stored asset stays far below the owner's size limit; SVG text is sanitized for the preview and
// sanitized again by the owner. The host stores the asset (`IconAssetSink`) and returns the value.
import { useState, type ClipboardEvent, type DragEvent, type KeyboardEvent } from "react";
import type { Strings } from "../pages/shared/i18n";
import type { IconValue } from "./iconValue";
import { sanitizeSVG } from "./svgSanitize";

export const MAX_IMAGE_SIDE = 256;
export const MAX_IMAGE_INPUT_BYTES = 20 * 1024 * 1024;
export const IMAGE_TYPES = ["image/png", "image/jpeg", "image/webp", "image/gif", "image/heic"];

export type AssetKind = "image" | "svg";

export interface IconAssetSink {
  /** Stores a prepared asset (PNG bytes or sanitized SVG text) and returns its icon value. */
  put(kind: AssetKind, data: Blob): Promise<IconValue>;
  /** The host downloads the URL (the page never fetches remote content) and stores it. */
  fromURL(kind: AssetKind, url: string): Promise<IconValue>;
}

/** Scales a raster image down to MAX_IMAGE_SIDE on its longer side, as PNG. */
export async function prepareImage(file: Blob): Promise<Blob> {
  const bitmap = await createImageBitmap(file);
  const scale = Math.min(1, MAX_IMAGE_SIDE / Math.max(bitmap.width, bitmap.height));
  const canvas = new OffscreenCanvas(
    Math.max(1, Math.round(bitmap.width * scale)),
    Math.max(1, Math.round(bitmap.height * scale)),
  );
  canvas.getContext("2d")?.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
  bitmap.close();
  return canvas.convertToBlob({ type: "image/png" });
}

export function AssetTab({
  kind,
  sink,
  strings,
  onPicked,
  onKeyDown,
  prepare = prepareImage,
}: {
  kind: AssetKind;
  sink: IconAssetSink | undefined;
  strings: Strings;
  onPicked: (value: IconValue) => void;
  /** The picker's keys (Escape, Ctrl-Tab) while a control of this tab has focus. */
  onKeyDown?: (event: KeyboardEvent<HTMLElement>) => void;
  prepare?: (file: Blob) => Promise<Blob>;
}) {
  const { t } = strings;
  const [url, setURL] = useState("");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [dragging, setDragging] = useState(false);

  const run = async (work: () => Promise<IconValue>) => {
    if (!sink) return setError(t("iconPicker.error.unavailable"));
    setBusy(true);
    setError(null);
    const outcome = await work().then(
      (value) => ({ value }),
      (cause: unknown) => ({ error: cause instanceof RefusalError ? t(cause.key) : t("iconPicker.error.failed") }),
    );
    setBusy(false);
    if ("value" in outcome) onPicked(outcome.value);
    else setError(outcome.error);
  };

  const accept = (file: File | null | undefined) => {
    if (!file) return;
    void run(async () => {
      if (kind === "svg") {
        if (file.type && file.type !== "image/svg+xml") throw new RefusalError("iconPicker.error.notSVG");
        const result = sanitizeSVG(await file.text());
        if (!result.ok)
          throw new RefusalError(
            result.reason === "tooLarge" ? "iconPicker.error.svgTooLarge" : "iconPicker.error.notSVG",
          );
        return sink!.put("svg", new Blob([result.svg], { type: "image/svg+xml" }));
      }
      if (!IMAGE_TYPES.includes(file.type)) throw new RefusalError("iconPicker.error.notImage");
      if (file.size > MAX_IMAGE_INPUT_BYTES) throw new RefusalError("iconPicker.error.imageTooLarge");
      return sink!.put("image", await prepare(file));
    });
  };

  const onDrop = (event: DragEvent) => {
    event.preventDefault();
    setDragging(false);
    accept(event.dataTransfer.files[0]);
  };
  const onPaste = (event: ClipboardEvent) => {
    const file = [...event.clipboardData.files][0];
    if (!file) return;
    event.preventDefault();
    accept(file);
  };
  const submitURL = () => {
    const text = url.trim();
    if (!/^https:\/\//i.test(text)) return setError(t("iconPicker.error.badURL"));
    void run(() => sink!.fromURL(kind, text));
  };

  return (
    <div
      className="icon-asset"
      data-dragging={dragging || undefined}
      onDragOver={(event) => {
        event.preventDefault();
        setDragging(true);
      }}
      onDragLeave={() => setDragging(false)}
      onDrop={onDrop}
      onPaste={onPaste}
    >
      <div className="icon-asset-drop">
        <span>{t(kind === "svg" ? "iconPicker.svg.drop" : "iconPicker.image.drop")}</span>
        <label className="icon-asset-choose">
          {t("iconPicker.asset.choose")}
          <input
            type="file"
            hidden
            aria-label={t("iconPicker.asset.choose")}
            accept={kind === "svg" ? "image/svg+xml,.svg" : IMAGE_TYPES.join(",")}
            onChange={(event) => accept(event.target.files?.[0])}
          />
        </label>
      </div>
      <form
        className="icon-asset-url"
        onSubmit={(event) => {
          event.preventDefault();
          submitURL();
        }}
      >
        <input
          type="url"
          value={url}
          placeholder={t("iconPicker.asset.urlPlaceholder")}
          aria-label={t("iconPicker.asset.url")}
          onChange={(event) => setURL(event.target.value)}
          onKeyDown={onKeyDown}
        />
        <button type="submit" disabled={busy || !url.trim()}>
          {t("iconPicker.asset.add")}
        </button>
      </form>
      <p className="icon-asset-hint">{t(kind === "svg" ? "iconPicker.svg.hint" : "iconPicker.image.hint")}</p>
      {error && (
        <p className="icon-asset-error" role="alert">
          {error}
        </p>
      )}
    </div>
  );
}

class RefusalError extends Error {
  constructor(readonly key: string) {
    super(key);
  }
}
