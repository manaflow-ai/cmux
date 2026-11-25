// l10n-allow-file: public-safe gallery fixtures.
import { useState } from "react";
import { GALLERY_NOW } from "../../gallery/clock";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import { emptySnapshot, gateSnapshot, manySnapshot, sampleSnapshot } from "./fixtures";
import { ForumPage } from "./ForumPage";
import type { ForumComposerMode, ForumLayout, ForumSnapshot } from "./types";

export type ForumGalleryProps = {
  layout?: ForumLayout;
  data?: "sample" | "many" | "empty" | "off" | "signed-out" | "loading" | "offline";
  space?: string;
  thread?: number;
  query?: string;
  composer?: ForumComposerMode;
};

function snapshotFor(data: ForumGalleryProps["data"]): ForumSnapshot {
  switch (data) {
    case "many":
      return manySnapshot();
    case "empty":
      return emptySnapshot();
    case "off":
      return gateSnapshot("off");
    case "signed-out":
      return gateSnapshot("signed-out");
    case "loading":
      return gateSnapshot("loading");
    case "offline":
      return { ...sampleSnapshot(), feed: "offline" };
    default:
      return sampleSnapshot();
  }
}

export function ForumGallery({
  layout = "columns",
  data = "sample",
  space,
  thread,
  query,
  composer,
}: ForumGalleryProps) {
  const [snapshot] = useState(() => snapshotFor(data));
  const [strings] = useState(() => createStrings(table, ["en"]));
  return (
    <ForumPage
      snapshot={snapshot}
      strings={strings}
      layout={layout}
      now={GALLERY_NOW}
      initialSpace={space ?? null}
      initialThread={thread ?? null}
      initialQuery={query}
      initialComposer={composer ?? null}
    />
  );
}
