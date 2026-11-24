// A local draft's picture can arrive after its path. Reserve one box from its first paint while
// resolving the path and sending independently. Only the renderer subscribes to this measurement.
import { useSyncExternalStore } from "react";

import { imageSize, thumbRatio } from "./imageWork";
import { videoShapeOf } from "./videoShape";

export const localDraftShape = Symbol("local draft tile shape");
export type LocalDraftShape = {
  read(): number;
  subscribe(paint: () => void): () => void;
};

export function draftShapeOf(file: File, video: boolean): LocalDraftShape {
  const hasSizeHeader = video
    ? /\.(mov|mp4|m4v)$/i.test(file.name) || /video\/(quicktime|mp4)/.test(file.type)
    : /\.(png|jpe?g|gif|webp)$/i.test(file.name) || /image\/(png|jpeg|gif|webp)/.test(file.type);
  let ratio = hasSizeHeader ? 0 : 1;
  const paints = new Set<() => void>();
  const settle = (value: number | undefined) => {
    if (ratio) return;
    ratio = value || 1;
    for (const paint of paints) paint();
    paints.clear();
  };
  if (hasSizeHeader) {
    const header = video
      ? videoShapeOf(file)
      : imageSize(file, () => ratio !== 0).then((size) =>
          size?.width && size.height ? thumbRatio(size.width, size.height) : undefined,
        );
    void header.then(settle, () => settle(undefined));
  }
  return {
    read: () => ratio,
    subscribe(paint) {
      if (ratio) return () => {};
      if (typeof requestAnimationFrame !== "function") {
        settle(undefined);
        return () => {};
      }
      paints.add(paint);
      // File-reading events share the renderer with the initial composer update. Give a supported
      // header three display frames from mount; an unsupported format has its square immediately.
      let frames = 3;
      let frame = requestAnimationFrame(function tick() {
        if (ratio) return;
        if (--frames) frame = requestAnimationFrame(tick);
        else settle(undefined);
      });
      return () => {
        paints.delete(paint);
        cancelAnimationFrame(frame);
      };
    },
  };
}

const absent = () => undefined;
const idle = () => () => {};
export function useDraftRatio(shape: LocalDraftShape | undefined): number | undefined {
  return useSyncExternalStore(shape?.subscribe ?? idle, shape?.read ?? absent, absent);
}
