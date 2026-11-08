// The "cmux Updated!" card's changes beside the sidebar (`#/surface/updated-notes`, the shipped
// look, updatedPreviewMode.ts): the native card host opens this page in the app's one hover card
// window, menu-wide, to the side of the sidebar, as the staged update card's highlights open. The
// card itself never grows.
//
// Lawrence 2026-11-07, on the list that grew up out of the bottom card over the sidebar's rows: "i
// dont like how it expands upwards, also it looks very bad". A calm header (what the app updated
// to, the full version, What's New), a hairline, then each change: its title whole, on as many
// lines as it needs, and a quiet detail under it (titles alone in the `beside-titles` look).
import { useEffect, useId, useRef, useState } from "react";
import { CARD_SCROLL_ATTRIBUTE, installScrollEdges } from "../../scrollers";
import { useDecoration } from "../../theme/decorations";
import type { Strings } from "../shared/i18n";
import type { ReleaseNotes } from "./types";
import type { UpdateHighlights, UpdateSurfaceActions } from "./updateHighlights";
import { previewEntries } from "./updatedPreview";
import { parsePreviewMode, type UpdatedPreviewMode } from "./updatedPreviewMode";
import { CopyVersion } from "./UpdateSurfaces";

export function UpdatedNotes({
  data,
  span,
  strings,
  actions,
  mode,
}: {
  data: UpdateHighlights;
  /** The notes of every build the update spans, newest first; absent until they load. */
  span?: ReleaseNotes[];
  strings: Strings;
  actions: UpdateSurfaceActions;
  /** The card's look (gallery); undefined reads the theme's. */
  mode?: UpdatedPreviewMode;
}) {
  const titleId = useId();
  const themed = parsePreviewMode(useDecoration("updated-card-preview"));
  const titlesOnly = (mode ?? themed) === "beside-titles";
  const [copied, setCopied] = useState(false);
  const scroller = useRef<HTMLElement | null>(null);
  const entries = previewEntries(data, span, strings.language);
  useEffect(() => (scroller.current ? installScrollEdges(scroller.current) : undefined), [entries.length]);
  const name = /^[^-]+-nightly\.\d+$/.test(data.version) ? strings.t("updates.card.nightly") : data.version;
  const titleKey = data.delivery === "background" ? "updates.card.updatedBehind" : "updates.card.updatedTo";
  const [before, after] = strings.format(titleKey, "\u0000").split("\u0000");
  return (
    <section
      className="wn-notes"
      data-titles={titlesOnly ? "" : undefined}
      aria-labelledby={titleId}
      ref={scroller}
      {...{ [CARD_SCROLL_ATTRIBUTE]: "" }}
    >
      <header className="wn-notes-head">
        <div className="wn-notes-title" id={titleId}>
          {before}
          {name}
          {after}
        </div>
        <button type="button" className="wn-notes-whatsnew" onClick={actions.openChangelog}>
          {strings.t("changelog.page.title")}
          <span aria-hidden="true"> ↗</span>
        </button>
        {/* The full version under the title, unless the title already says it (a release). */}
        {name !== data.version && (
          <div className="wn-notes-version">
            <CopyVersion version={data.version} strings={strings} onCopied={setCopied}>
              {data.version}
            </CopyVersion>
            <span aria-live="polite">{copied && ` · ${strings.t("updates.card.copied")}`}</span>
          </div>
        )}
      </header>
      {entries.length > 0 && (
        <ul className="wn-notes-list" aria-label={strings.t("changelog.page.title")}>
          {entries.map((entry) => (
            <li key={entry.id}>
              <button type="button" className="wn-notes-row" onClick={actions.openChangelog}>
                <span className="wn-notes-row-title">{entry.title}</span>
                {!titlesOnly && entry.detail && <span className="wn-notes-row-detail">{entry.detail}</span>}
              </button>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}
