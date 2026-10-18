"use client";

import { useTranslations } from "next-intl";
import { useRef, useState, type ReactNode } from "react";
import Cropper from "react-easy-crop";
import { InlineError } from "./feedback";
import { UploadIcon } from "./icons";
import {
  compressJpegDataUrl,
  cropToJpegDataUrl,
  isImageFile,
  loadImage,
  readFileAsDataUrl,
  type PixelCrop,
} from "./image-crop";
import { settingsButtonClass } from "./styles";
import { useAsyncAction } from "./use-async-action";

/**
 * Upload, round-crop (aspect 1, zoom 1-3), compress (~100 KB JPEG) and save
 * an avatar image. Used for the user profile image and reusable for team
 * images. `onRemove` adds a "Remove image" button when an image is set.
 */
export function ImageCropEditor({
  imageUrl,
  preview,
  onSave,
  onRemove,
  label,
}: {
  readonly imageUrl: string | null;
  /** The current avatar rendering (for example `<UserAvatar />`). */
  readonly preview: ReactNode;
  readonly onSave: (dataUrl: string) => Promise<void>;
  readonly onRemove?: () => Promise<void>;
  /** Accessible name for the upload button. */
  readonly label: string;
}) {
  const t = useTranslations("dashboard.settings.ui");
  const inputRef = useRef<HTMLInputElement>(null);
  const [rawUrl, setRawUrl] = useState<string | null>(null);
  const [crop, setCrop] = useState({ x: 0, y: 0 });
  const [zoom, setZoom] = useState(1);
  const [area, setArea] = useState<PixelCrop | null>(null);
  const [run, state] = useAsyncAction(t("imageSaveError"));

  const reset = () => {
    setRawUrl(null);
    setCrop({ x: 0, y: 0 });
    setZoom(1);
    setArea(null);
    state.clearError();
  };

  const pickFile = async (file: File | undefined) => {
    if (!file) return;
    state.clearError();
    if (!isImageFile(file)) {
      state.setError(t("invalidImage"));
      return;
    }
    try {
      const url = await readFileAsDataUrl(file);
      await loadImage(url);
      setRawUrl(url);
    } catch {
      state.setError(t("invalidImage"));
    }
  };

  const save = () =>
    run(async () => {
      if (!rawUrl || !area) return;
      const cropped = await cropToJpegDataUrl(rawUrl, area);
      if (!cropped) throw new Error("crop failed");
      await onSave(await compressJpegDataUrl(cropped));
      reset();
    });

  const fileInput = (
    <input
      ref={inputRef}
      type="file"
      accept="image/*"
      hidden
      onChange={(event) => {
        const file = event.target.files?.[0];
        event.target.value = "";
        void pickFile(file);
      }}
    />
  );

  if (!rawUrl) {
    return (
      <div className="flex flex-col gap-2 sm:items-end">
        {fileInput}
        <div className="flex items-center gap-3">
          <button
            type="button"
            aria-label={label}
            onClick={() => inputRef.current?.click()}
            className="group relative rounded-full focus-visible:outline focus-visible:outline-1 focus-visible:outline-foreground"
          >
            {preview}
            <span className="absolute inset-0 flex items-center justify-center rounded-full bg-black/40 text-white opacity-0 transition-opacity group-hover:opacity-100 group-focus-visible:opacity-100">
              <UploadIcon />
            </span>
          </button>
          <div className="flex flex-wrap gap-2">
            <button type="button" onClick={() => inputRef.current?.click()} className={settingsButtonClass("secondary", "sm")}>
              {t("uploadImage")}
            </button>
            {imageUrl && onRemove ? (
              <button
                type="button"
                disabled={state.pending}
                onClick={() => void run(onRemove)}
                className={settingsButtonClass("ghost", "sm")}
              >
                {t("removeImage")}
              </button>
            ) : null}
          </div>
        </div>
        <InlineError message={state.error} />
      </div>
    );
  }

  return (
    <div className="flex flex-col items-center gap-3">
      <div className="relative size-64 bg-code-bg">
        <Cropper
          image={rawUrl}
          crop={crop}
          zoom={zoom}
          minZoom={1}
          maxZoom={3}
          aspect={1}
          cropShape="round"
          showGrid={false}
          onCropChange={setCrop}
          onZoomChange={setZoom}
          onCropComplete={(_area, pixels) => setArea(pixels)}
        />
      </div>
      <input
        type="range"
        aria-label={t("zoom")}
        min={1}
        max={3}
        step={0.1}
        value={zoom}
        onChange={(event) => setZoom(Number(event.target.value))}
        className="w-64"
      />
      <div className="flex gap-2">
        <button
          type="button"
          disabled={state.pending || !area}
          onClick={() => void save()}
          className={settingsButtonClass("primary", "sm")}
        >
          {state.pending ? t("saving") : t("save")}
        </button>
        <button type="button" disabled={state.pending} onClick={reset} className={settingsButtonClass("secondary", "sm")}>
          {t("cancel")}
        </button>
      </div>
      <InlineError message={state.error} />
    </div>
  );
}
