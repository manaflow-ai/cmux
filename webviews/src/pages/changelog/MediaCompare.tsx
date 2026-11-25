// A highlight's before/after pair on What's New: the shared pair (ui/MediaCompare.tsx) in the
// page's compare mode (the route's `compare=`, for the gallery) and words.
import { createContext, useContext } from "react";
import { MediaCompare as Pair } from "../../ui/MediaCompare";
import type { Strings } from "../shared/i18n";
import type { CompareMode } from "./types";

/** The page's compare mode; ChangelogPage provides the route's. */
export const CompareModeContext = createContext<CompareMode>("slider");

export function MediaCompare({
  after,
  alt,
  before,
  strings,
  fit = "cover",
}: {
  after: string;
  alt: string;
  before: { src: string; alt: string };
  strings: Strings;
  /** `contain` in the lightbox: the after picture sets the box, shown whole. */
  fit?: "cover" | "contain";
}) {
  const mode = useContext(CompareModeContext);
  const labels = {
    before: strings.t("changelog.compare.before"),
    after: strings.t("changelog.compare.after"),
    drag: strings.t("changelog.compare.drag"),
    show: strings.t("changelog.compare.show"),
  };
  return <Pair after={{ src: after, alt }} before={before} labels={labels} mode={mode} fit={fit} />;
}
