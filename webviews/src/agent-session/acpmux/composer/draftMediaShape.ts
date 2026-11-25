// A local draft's picture can arrive after its path. Reserve one box from its first paint while
// resolving the path and sending independently. Only the renderer subscribes to this measurement.
import { useSyncExternalStore } from "react";

import { imageSize, thumbRatio } from "./imageWork";
import { videoShapeOf } from "./videoShape";

export const localDraftShape = Symbol("local draft tile shape");
export type LocalDraftShape = {
  read(): number;
  /** The box the draft drew, or a known header ratio when the file was sent before mounting. */
  forSend(): number | undefined;
  subscribe(paint: () => void): () => void;
};

export function draftShapeOf(file: File, video: boolean): LocalDraftShape {
  const hasSizeHeader = video
    ? /\.(mov|mp4|m4v)$/i.test(file.name) || /video\/(quicktime|mp4)/.test(file.type)
    : /\.(png|jpe?g|gif|webp)$/i.test(file.name) || /image\/(png|jpeg|gif|webp)/.test(file.type);
  let ratio = hasSizeHeader ? 0 : 1;
  let measured: number | undefined;
  let displayed: number | undefined;
  const paints = new Set<() => void>();
  const settle = (value: number | undefined) => {
    if (ratio) return;
    ratio = value || 1;
    if (paints.size) displayed = ratio;
    for (const paint of paints) paint();
    paints.clear();
  };
  if (hasSizeHeader) {
    const header = video
      ? videoShapeOf(file)
      : imageSize(file, () => ratio !== 0).then((size) =>
          size?.width && size.height ? thumbRatio(size.width, size.height) : undefined,
        );
    void header.then(
      (value) => {
        measured = value;
        settle(value);
      },
      () => settle(undefined),
    );
  }
  return {
    read: () => ratio,
    forSend: () => displayed ?? measured,
    subscribe(paint) {
      if (ratio) {
        displayed = ratio;
        return () => {};
      }
      if (typeof requestAnimationFrame !== "function") {
        settle(undefined);
        return () => {};
      }
      paints.add(paint);
      // Videos can keep a square when the header misses the first paint. The sent image shows
      // the full picture, so allow its short header read three frames to preserve that aspect.
      let frames = video ? 1 : 3;
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
