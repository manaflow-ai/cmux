// The pane's image viewer (ImageViewer.tsx): the chat's images from when it opened, at the one the
// reader clicked. Another chat closes it, and so does the chat leaving this Mac (chips/locality.ts):
// a local file's image it holds was this Mac's to show only while the chat ran here.
import { useCallback, useEffect, useState } from "react";
import { onLocalityChange } from "../chips/locality";
import type { AcpmuxRow } from "../model";
import { chatImages, type ChatImage } from "./chatImages";

export type ImageView = { images: ChatImage[]; index: number };

/// `rows` reads the chat's rows when an image opens; `sessionId` is the chat shown.
export function useImageView(rows: () => readonly AcpmuxRow[], sessionId: string | undefined) {
  const [imageView, setImageView] = useState<ImageView | undefined>();
  const openImage = useCallback(
    (src: string, alt: string, path?: string) => {
      const images = chatImages(rows());
      const index = images.findIndex((image) => image.src === src);
      if (index < 0) setImageView({ images: [{ src, alt, path }], index: 0 });
      else
        setImageView({ images: images.map((image, i) => (i === index && path ? { ...image, path } : image)), index });
    },
    [rows],
  );
  useEffect(() => setImageView(undefined), [sessionId]);
  useEffect(
    () =>
      onLocalityChange((before) => {
        if (before.locality === "local") setImageView(undefined);
      }),
    [],
  );
  return { imageView, setImageView, openImage };
}
