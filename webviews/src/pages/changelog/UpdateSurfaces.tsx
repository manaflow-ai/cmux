// The update surfaces of the What's New system (cx-urd.61, Lawrence picked card A and popover A,
// 2026-10-11), in the same tokens and type steps as the changelog page:
//  - UpdatedCard (after an update, the sidebar's bottom card slot): the composer's surface, as every
//    sidebar card (Leo 2026-10-13). Short (Lawrence 2026-10-31, msg 19218: "it looks like too much
//    text"; picked from cmux-shots/whatsnew-variations): "Updated to Nightly", the update's one top
//    change ("Sidebar: …", the first area's first change, updateSummary.ts) and a What's New button.
//    No date, build line, change list or "+N more" (they were 2026-10-20 to 10-26): the full build
//    is in About, and a click on "Nightly" copies it (no tooltip: "seems excessive"). An update
//    with nothing a person would notice says "Maintenance and fixes"; "What's new in this build" is
//    the last resort while nothing is known. The x shows only on hover or keyboard focus; in the
//    sidebar the host draws it natively (SidebarUpdatedCardHost) and Escape closes it. Share cmux
//    is the palette's (app.shareCmux).
//  - UpdateReadyHighlights (hovering the staged "Restart to Update" card): only what the card lacks
//    (Leo 2026-10-13; the card has Update Ready, the short version and the date): a quiet "What's
//    new in nightly 3845050" (a click on the version copies the full build, no tooltip: 2026-10-31), the top three changes
//    numbered, each a title, one line and its picture when it has one, and "See all changes", once.
//    The popover scrolls on to every other change of the update (`rest`, 2026-10-20), with the
//    shared card scroller and a fade at each edge that has more past it (scrollers.ts).
//    Under the title, the version it replaces ("Updating from nightly 3801702", Lawrence 2026-10-19:
//    show at once what is going to change); with no change list, "See release notes" instead.
// Data: UpdateHighlights (updateHighlights.ts); the host mounts these and wires the actions.
import { useEffect, useId, useRef, useState, useSyncExternalStore, type MouseEvent } from "react";
import { CARD_SCROLL_ATTRIBUTE, installScrollEdges } from "../../scrollers";
import { ChangePullRequest } from "./ChangePullRequest";
import { getColorScheme, subscribeColorScheme } from "./colorScheme";
import { distinctSummary, readableUpdate } from "./model";
import type { Strings } from "../shared/i18n";
import type { ReleaseNotes } from "./types";
import type { UpdateHighlightMedia, UpdateHighlights, UpdateSurfaceActions } from "./updateHighlights";
import { summarizeHighlights, summarizeUpdate, type SummaryRow } from "./updateSummary";

/** "1.0.0-nightly.3845050428001" reads "nightly 3845050", as the native Update Ready card
 * (UpdateChangelog.cardVersion): every nightly is 1.0.0. Any other version reads as itself. */
export function cardVersion(version: string): string {
  const match = /^[^-]+-nightly\.(\d+)$/.exec(version);
  return match ? `nightly ${match[1]!.slice(0, 7)}` : version;
}

/** Writes `text` to the clipboard: the Clipboard API, else a hidden textarea and Copy (a page whose
 * origin the API refuses). Rejects when neither copies. */
async function copyVersion(text: string): Promise<void> {
  try {
    await navigator.clipboard.writeText(text);
    return;
  } catch {
    // Fall through to the textarea.
  }
  const area = document.createElement("textarea");
  area.value = text;
  area.setAttribute("readonly", "");
  area.style.position = "fixed";
  area.style.opacity = "0";
  document.body.append(area);
  area.select();
  const ok = document.execCommand("copy");
  area.remove();
  if (!ok) throw new Error("Clipboard copy failed");
}

/** How long a copied version says "Copied". */
const COPIED_MS = 1500;

/** A short version that copies the full one: selectable text, no tooltip (2026-10-31, Lawrence on
 * the hover that covered the Updated card's build line with "1.0.0-nightly.4124615690001": "seems
 * excessive"). It is a native <button>: a click, Return or Space copies `version` for a bug report
 * and `copied` is true for a moment, for the caller to say "Copied" in place: nothing pops over the
 * surface. Its CSS keeps it plain inline text, and a drag across the line still selects it with the
 * words around it (u4466); a pointer click that ends a selection copies nothing. */
function CopyVersion({
  version,
  className,
  strings,
  onCopied,
  children,
}: {
  version: string;
  className?: string;
  strings: Strings;
  onCopied: (copied: boolean) => void;
  children: string;
}) {
  const timer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  useEffect(() => () => clearTimeout(timer.current), []);
  const copy = (event: MouseEvent) => {
    // A pointer click that ends a selection drag selects; Return or Space (detail 0) always copies.
    if (event.detail !== 0 && globalThis.getSelection?.()?.isCollapsed === false) return;
    void copyVersion(version).then(
      () => {
        onCopied(true);
        clearTimeout(timer.current);
        timer.current = setTimeout(() => onCopied(false), COPIED_MS);
      },
      () => undefined,
    );
  };
  return (
    <button
      type="button"
      className={className ? `wn-copy-version ${className}` : "wn-copy-version"}
      aria-label={strings.format("updates.card.copyVersion", version)}
      onClick={copy}
    >
      {children}
    </button>
  );
}

/** "What's new in nightly 3845050": the version copies the full build (CopyVersion), then the
 * heading says "· Copied" after it for a moment (2026-10-31: it had the full build in a tooltip). */
function PopoverTitle({ id, version, strings }: { id: string; version: string; strings: Strings }) {
  const [copied, setCopied] = useState(false);
  const [before, after] = strings.format("updates.popover.title", "\u0000").split("\u0000");
  return (
    <div className="wn-pop-title" id={id}>
      {before}
      <CopyVersion version={version} strings={strings} onCopied={setCopied}>
        {cardVersion(version)}
      </CopyVersion>
      {after}
      <span aria-live="polite">{copied && ` · ${strings.t("updates.card.copied")}`}</span>
    </div>
  );
}

export function UpdatedCard({
  data,
  span,
  strings,
  actions,
  closeButton = true,
  glass = true,
}: {
  data: UpdateHighlights;
  /** The notes of every build after the previous version, newest first; absent until they load. */
  span?: ReleaseNotes[];
  strings: Strings;
  actions: UpdateSurfaceActions;
  /** Draws the x (with `actions.dismiss`); false where the host draws its own (the sidebar's). */
  closeButton?: boolean;
  /** Draws the card's own glass; false where the host draws it under the page (the sidebar's
      CardSurfaceView, SidebarUpdatedCardHost): a page's glass sees nothing of the native sidebar,
      and with no `.ui-glass` in the document the lens draws no wallpaper copy over the host's. */
  glass?: boolean;
}) {
  const titleId = useId();
  const [copied, setCopied] = useState(false);
  const summary = span ? summarizeUpdate(span, strings.language) : summarizeHighlights(readableUpdate(data));
  const top = summary.rows[0];
  const name = /^[^-]+-nightly\.\d+$/.test(data.version) ? strings.t("updates.card.nightly") : data.version;
  const [before, after] = strings.format("updates.card.updatedTo", "\u0000").split("\u0000");
  return (
    <section className={glass ? "ui-glass wn-card" : "wn-card"} aria-labelledby={titleId}>
      <div className="wn-card-title" id={titleId}>
        {before}
        <CopyVersion version={data.version} strings={strings} onCopied={setCopied}>
          {name}
        </CopyVersion>
        {after}
        <span aria-live="polite">{copied && ` · ${strings.t("updates.card.copied")}`}</span>
      </div>
      {closeButton && actions.dismiss && (
        <button
          type="button"
          className="wn-card-close"
          aria-label={strings.t("updates.card.dismiss")}
          onClick={actions.dismiss}
        >
          <svg viewBox="0 0 10 10" aria-hidden="true">
            <path d="M2 2l6 6M8 2l-6 6" />
          </svg>
        </button>
      )}
      <p className="wn-card-note">
        {top ? (
          <>
            <span className="wn-card-area">{strings.format("updates.card.areaLabel", rowLabel(top, strings))}</span>{" "}
            {top.phrases[0]}
          </>
        ) : (
          strings.t(span ? "changelog.page.maintenance" : "updates.card.whatsNewInBuild")
        )}
      </p>
      <div className="wn-card-actions">
        <button type="button" className="wn-card-primary" onClick={actions.openChangelog}>
          {strings.t("changelog.page.title")}
        </button>
      </div>
    </section>
  );
}

export function UpdateReadyHighlights({
  data,
  strings,
  actions,
}: {
  data: UpdateHighlights;
  strings: Strings;
  actions: UpdateSurfaceActions;
}) {
  const titleId = useId();
  const scroller = useRef<HTMLElement>(null);
  const readable = readableUpdate(data);
  const items = readable.items;
  const rest = readable.rest ?? null;
  useEffect(() => (scroller.current ? installScrollEdges(scroller.current) : undefined), [data]);
  return (
    <section className="wn-pop" aria-labelledby={titleId} ref={scroller} {...{ [CARD_SCROLL_ATTRIBUTE]: "" }}>
      <PopoverTitle id={titleId} version={data.version} strings={strings} />
      {data.fromVersion && data.fromVersion !== data.version && (
        <div className="wn-pop-from">{strings.format("updates.popover.from", cardVersion(data.fromVersion))}</div>
      )}
      {items.length > 0 && (
        <ol className="wn-pop-list">
          {items.map((item, index) => (
            <li key={item.id}>
              <span className="wn-pop-n" aria-hidden="true">
                {index + 1}
              </span>
              <div>
                <span className="wn-pop-item">
                  {item.pr ? <ChangePullRequest pr={item.pr} title={item.title} /> : item.title}
                </span>
                {item.summary && distinctSummary(item.title, item.summary) && (
                  <span className="wn-pop-line">{item.summary}</span>
                )}
                {item.media && <PopMedia media={item.media} onOpen={actions.openChangelog} />}
              </div>
            </li>
          ))}
        </ol>
      )}
      {rest && rest.length > 0 && (
        <div className="wn-pop-rest">
          {REST_ORDER.map((category) => {
            const items = rest.filter((item) => item.category === category);
            if (items.length === 0) return null;
            return (
              <section
                key={category}
                className="wn-pop-rest-group"
                aria-label={strings.t(`changelog.group.${category}`)}
              >
                <h4>{strings.t(`changelog.group.${category}`)}</h4>
                <ul>
                  {items.map((item) => (
                    <li key={item.id}>
                      {item.pr ? <ChangePullRequest pr={item.pr} title={item.title} /> : item.title}
                    </li>
                  ))}
                </ul>
              </section>
            );
          })}
        </div>
      )}
      <div className="wn-pop-foot">
        {!rest && data.moreCount > 0 && (
          <span className="wn-pop-more">{strings.format("updates.card.more", String(data.moreCount))}</span>
        )}
        <button type="button" className="wn-pop-all" onClick={actions.openChangelog}>
          {strings.t(
            items.length > 0 || (rest?.length ?? 0) > 0 ? "updates.popover.seeAll" : "updates.popover.seeReleaseNotes",
          )}
          <span aria-hidden="true"> →</span>
        </button>
      </div>
    </section>
  );
}

/** "Updated to Nightly · Oct 26, 7:38 PM" as parts that each keep one line: a narrow sidebar wraps
    the line between them, never inside a time or cuts it off. */
/** A row's name: the area ("Sidebar"), else the category its changes share ("Fixed"). */
function rowLabel(row: SummaryRow, strings: Strings): string {
  return row.area ? strings.t(`updates.area.${row.area}`) : strings.t(`changelog.group.${row.category ?? "improved"}`);
}

/** The rest of an update reads as Conductor's release pages do: New, Improved, Fixed, Security. */
const REST_ORDER = ["new", "improved", "fixed", "security"] as const;

/** A change's picture at the popover's width, in the theme's scheme; a click opens the change's
 * notes, where it shows at the page's width. Only `data:` pictures reach it (the host inlines
 * and checks each file, ReleaseMediaStore). */
function PopMedia({ media, onOpen }: { media: UpdateHighlightMedia; onOpen: () => void }) {
  const scheme = useSyncExternalStore(subscribeColorScheme, getColorScheme, () => "light" as const);
  const src = scheme === "dark" ? media.dark : media.light;
  // Anything but an inlined picture (a remote or relative URL) never loads here.
  if (!src.startsWith("data:image/")) return null;
  return (
    <button type="button" className="wn-pop-media" onClick={onOpen} aria-label={media.alt}>
      <img key={src} src={src} alt="" decoding="async" />
    </button>
  );
}
