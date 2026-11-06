// The update surfaces of the What's New system (cx-urd.61, Lawrence picked card A and popover A,
// 2026-10-11), in the same tokens and type steps as the changelog page:
//  - UpdatedCard (after an update, the sidebar's bottom card slot): the theme's surface (Leo
//    2026-11-02: "why is the update thing unthemed"; the sidebar's CardSurfaceView.takesThemeTint). Short (Lawrence 2026-10-31, msg 19218: "it looks like too much
//    text"; picked from cmux-shots/whatsnew-variations): "Updated to Nightly", the update's one top
//    change ("Sidebar: …", the first area's first change, updateSummary.ts) and a What's New button.
//    No date, build line, change list or "+N more" (they were 2026-10-20 to 10-26): the full build
//    is in About, and a click on "Nightly" copies it (no tooltip: "seems excessive"). An automatic
//    install that relaunched cmux behind another app says "Updated to Nightly in the background"
//    (2026-11-03: the card had seemed to come without a restart). An update
//    with nothing a person would notice says "Maintenance and fixes"; "What's new in this build" is
//    the last resort while nothing is known. The x shows only on hover or keyboard focus; in the
//    sidebar the host draws it natively (SidebarUpdatedCardHost) and Escape closes it. Share cmux
//    is the palette's (app.shareCmux).
//  - UpdateReadyHighlights (hovering the staged "Restart to Update" card): a hover card (Leo
//    2026-11-05: "this is too big ... oddly spaced and oddly rendered ... i can't even scroll
//    through the changes from that preview!"). One heading line, version to version ("nightly
//    3801702 → nightly 3845050"; a click on the new version copies the full build, no tooltip:
//    2026-10-31), then every change of the update one line each (the title, then its line in the
//    quiet color, cut at the edge; a picture as a thumbnail), the builds the update skips too
//    (`span`), and "See all changes" pinned at the bottom. Only the list scrolls, with the shared
//    card scroller and a fade at each edge that has more past it (scrollers.ts); the card is at
//    most a hover card's size. With no change list, the versions and "See release notes".
// Data: UpdateHighlights (updateHighlights.ts); the host mounts these and wires the actions.
import { useEffect, useId, useRef, useState, useSyncExternalStore, type MouseEvent } from "react";
import { CARD_SCROLL_ATTRIBUTE, installScrollEdges } from "../../scrollers";
import { ChangePullRequest } from "./ChangePullRequest";
import { getColorScheme, subscribeColorScheme } from "./colorScheme";
import { Doodle, DoodleActions, DoodleHeadline } from "./doodle/UpdateDoodle";
import { useDecoration } from "../../theme/decorations";
import { distinctSummary, mergedView, readableUpdate, titleKey } from "./model";
import type { Strings } from "../shared/i18n";
import type { ReleaseNotes } from "./types";
import type {
  UpdateHighlightItem,
  UpdateHighlightMedia,
  UpdateHighlights,
  UpdateSurfaceActions,
} from "./updateHighlights";
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

/** The popover's one heading line, version to version (Leo 2026-11-05: "this is too big"):
 * "nightly 4210546 → nightly 4212118", the version it updates to in the text color, a click on it
 * copying the full build. With no other version known it says "What's new in nightly 4212118". */
function PopoverHead({
  id,
  version,
  from,
  strings,
}: {
  id: string;
  version: string;
  from: string | null;
  strings: Strings;
}) {
  const [copied, setCopied] = useState(false);
  if (!from) return <PopoverTitle id={id} version={version} strings={strings} />;
  const parts = strings.format("updates.popover.span", "\u0000", "\u0001").split(/(\u0000|\u0001)/u);
  return (
    <div className="wn-pop-title wn-pop-span" id={id}>
      {parts.map((part, index) =>
        part === "\u0000" ? (
          <span key={index} className="wn-pop-span-from">
            {cardVersion(from)}
          </span>
        ) : part === "\u0001" ? (
          <CopyVersion key={index} version={version} className="wn-pop-span-to" strings={strings} onCopied={setCopied}>
            {cardVersion(version)}
          </CopyVersion>
        ) : (
          part
        ),
      )}
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
  decoration,
  animate = true,
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
  /** The decoration in the card's slot (ThemeDecorations `updated-card`); undefined reads the theme's. */
  decoration?: string | null;
  /** The doodle draws on (false: drawn from the start, for stills). */
  animate?: boolean;
}) {
  const titleId = useId();
  const [copied, setCopied] = useState(false);
  const themed = useDecoration("updated-card");
  const doodle = (decoration === undefined ? themed : decoration) === "doodle";
  const summary = span ? summarizeUpdate(span, strings.language) : summarizeHighlights(readableUpdate(data));
  const top = summary.rows[0];
  const name = /^[^-]+-nightly\.\d+$/.test(data.version) ? strings.t("updates.card.nightly") : data.version;
  const titleKey = data.delivery === "background" ? "updates.card.updatedBehind" : "updates.card.updatedTo";
  const [before, after] = strings.format(titleKey, "\u0000").split("\u0000");
  const whatsNew = (
    <button type="button" className="wn-card-primary" onClick={actions.openChangelog}>
      {strings.t("changelog.page.title")}
    </button>
  );
  const card = (
    <section
      className={glass ? "ui-glass wn-card" : "wn-card"}
      aria-labelledby={titleId}
      data-decoration={doodle ? "doodle" : undefined}
    >
      {doodle && <DoodleHeadline version={cardVersion(data.version)} strings={strings} />}
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
      {doodle ? (
        <DoodleActions strings={strings} whatsNew={whatsNew} onGotIt={actions.dismiss} />
      ) : (
        <div className="wn-card-actions">{whatsNew}</div>
      )}
    </section>
  );
  return doodle ? <Doodle animate={animate}>{card}</Doodle> : card;
}

/** How the popover lays out an update with no change list (title, from line, link): the link
 * under the from line (`stacked`, shipped), at the end of the from line (`inline`), or at the end
 * of the title line (`title-row`). Gallery variants (Leo 2026-11-03: "stretched out wasted space"). */
export type BriefLayout = "stacked" | "inline" | "title-row";

/** How the popover with a change list lays out a change: its title on one line and its line under
 * it, cut to one line (`two-line`, shipped); the line after the title on the same line (`line`,
 * which cut most lines to a stub such as "The or…"); or that with no New / Improved / Fixed
 * headings (`flat`). Gallery variants (Leo 2026-11-05: "this is too big"). */
export type ReadyLayout = "line" | "two-line" | "flat";

export function UpdateReadyHighlights({
  data,
  span,
  strings,
  actions,
  briefLayout = "stacked",
  layout = "two-line",
}: {
  data: UpdateHighlights;
  /** The notes of every build after the running version up to the staged one, newest first: the
   *  popover lists every change of the update, not only the staged build's. */
  span?: ReleaseNotes[];
  strings: Strings;
  actions: UpdateSurfaceActions;
  briefLayout?: BriefLayout;
  layout?: ReadyLayout;
}) {
  const titleId = useId();
  const scroller = useRef<HTMLElement | null>(null);
  // One callback for both scrollers: the brief popover's section and the list's div.
  const scrollerRef = (element: HTMLElement | null) => {
    scroller.current = element;
  };
  const readable = withSpan(readableUpdate(data), span, strings.language);
  const items = readable.items;
  const rest = readable.rest ?? null;
  useEffect(() => (scroller.current ? installScrollEdges(scroller.current) : undefined), [items.length, rest?.length]);
  // Keys pressed while nothing in the page has the focus scroll the list (the hover card's page
  // gets the keys once a click made its window key, before any Tab).
  useEffect(() => {
    const keydown = (event: KeyboardEvent) => {
      const list = scroller.current;
      if (!list || event.defaultPrevented || event.target !== list.ownerDocument.body) return;
      const step = SCROLL_KEYS[event.key];
      if (step === undefined) return;
      event.preventDefault();
      const page = list.clientHeight * 0.9;
      if (step === "start") list.scrollTop = 0;
      else if (step === "end") list.scrollTop = list.scrollHeight;
      else list.scrollTop += step === "page" ? page : step === "-page" ? -page : step;
    };
    document.addEventListener("keydown", keydown);
    return () => document.removeEventListener("keydown", keydown);
  }, []);
  // No change list (Leo 2026-11-03: "MAN this looks ugly... stretched out wasted space"): the popover
  // is as wide as its lines (at most the menu width) and the link sits with them, with no rule and
  // no far edge to push it to. The host sizes the popover to the width this page reports.
  if (items.length === 0 && (rest?.length ?? 0) === 0) {
    const from = data.fromVersion && data.fromVersion !== data.version ? data.fromVersion : null;
    const link = (
      <button type="button" className="wn-pop-all" onClick={actions.openChangelog}>
        {strings.t("updates.popover.seeReleaseNotes")}
        <span aria-hidden="true"> →</span>
      </button>
    );
    return (
      <section
        className="wn-pop wn-pop-brief"
        data-layout={briefLayout}
        aria-labelledby={titleId}
        ref={scrollerRef}
        {...{ [CARD_SCROLL_ATTRIBUTE]: "" }}
      >
        <div className="wn-pop-head">
          <PopoverTitle id={titleId} version={data.version} strings={strings} />
          {briefLayout === "title-row" && link}
        </div>
        {from && (
          <div className="wn-pop-from">
            {strings.format("updates.popover.from", cardVersion(from))}
            {briefLayout === "inline" && (
              <>
                <span aria-hidden="true"> · </span>
                {link}
              </>
            )}
          </div>
        )}
        {(briefLayout === "stacked" || (briefLayout === "inline" && !from)) && link}
        {data.moreCount > 0 && (
          <div className="wn-pop-more">{strings.format("updates.card.more", String(data.moreCount))}</div>
        )}
      </section>
    );
  }
  const from = data.fromVersion && data.fromVersion !== data.version ? data.fromVersion : null;
  const all = [...items, ...(rest ?? [])];
  const groups =
    layout === "flat"
      ? [{ key: "all", label: null, items: rest ?? [] }]
      : REST_ORDER.map((category) => ({
          key: category,
          label: strings.t(`changelog.group.${category}`),
          items: (rest ?? []).filter((item) => item.category === category),
        }));
  return (
    <section className="wn-pop" data-layout={layout} aria-labelledby={titleId}>
      <PopoverHead id={titleId} version={data.version} from={from} strings={strings} />
      <div
        className="wn-pop-scroll"
        ref={scrollerRef}
        // Arrow keys, Page Up/Down, Home and End scroll the list once it has the focus.
        tabIndex={0}
        aria-labelledby={titleId}
        {...{ [CARD_SCROLL_ATTRIBUTE]: "" }}
      >
        {items.length > 0 && (
          <ul className="wn-pop-list">
            {items.map((item) => (
              <PopRow key={item.id} item={item} layout={layout} onOpen={actions.openChangelog} />
            ))}
          </ul>
        )}
        {rest && rest.length > 0 && (
          <div className="wn-pop-rest">
            {groups.map(({ key, label, items }) =>
              items.length === 0 ? null : (
                <section key={key} className="wn-pop-rest-group" aria-label={label ?? undefined}>
                  {label && <h4>{label}</h4>}
                  <ul>
                    {items.map((item) => (
                      <PopRow key={item.id} item={item} layout={layout} onOpen={actions.openChangelog} />
                    ))}
                  </ul>
                </section>
              ),
            )}
          </div>
        )}
      </div>
      <div className="wn-pop-foot">
        {!rest && data.moreCount > 0 && (
          <span className="wn-pop-more">{strings.format("updates.card.more", String(data.moreCount))}</span>
        )}
        <button type="button" className="wn-pop-all" onClick={actions.openChangelog}>
          {strings.t(all.length > 0 ? "updates.popover.seeAll" : "updates.popover.seeReleaseNotes")}
          <span aria-hidden="true"> →</span>
        </button>
      </div>
    </section>
  );
}

/** One change (Leo 2026-11-05: "this is too big ... oddly spaced"): its title on one line, then in
 * the quiet color only what its line adds, on one line under it, each cut at the popover's edge as
 * the What's New sheet's rows are (`line` and `flat` put both on one line). A picture is a small
 * thumbnail at the row's end; a click on it opens the change's notes. */
function PopRow({ item, layout, onOpen }: { item: UpdateHighlightItem; layout: ReadyLayout; onOpen: () => void }) {
  const line = item.summary ? distinctSummary(item.title, item.summary) : "";
  return (
    <li className="wn-pop-row">
      <span className="wn-pop-text">
        <span className="wn-pop-item">
          {item.pr ? <ChangePullRequest pr={item.pr} title={item.title} /> : item.title}
        </span>
        {line && (
          <>
            {layout !== "two-line" && " "}
            <span className="wn-pop-line">{line}</span>
          </>
        )}
      </span>
      {item.media && <PopMedia media={item.media} onOpen={onOpen} />}
    </li>
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

/** The list's scroll keys while the page has no focused control: a line, a page or an end. */
const SCROLL_KEYS: Record<string, number | "page" | "-page" | "start" | "end"> = {
  ArrowDown: 40,
  ArrowUp: -40,
  PageDown: "page",
  PageUp: "-page",
  " ": "page",
  Home: "start",
  End: "end",
};

/** The update with every change of the builds it spans (`span`, newest first, the page's notes):
 * the staged build's own items first, then each other build's readable changes once, so an
 * update across several nightlies lists all of them (Leo 2026-11-05: "i can't even scroll
 * through the changes from that preview!"). Without notes, the host's items as they are. */
function withSpan(data: UpdateHighlights, span: ReleaseNotes[] | undefined, language: string): UpdateHighlights {
  if (!span || span.length === 0) return data;
  const view = mergedView(span, language);
  const spanned = [view.hero, ...view.groups.flatMap((group) => group.items)].flatMap((item) =>
    item
      ? [
          {
            // Its own namespace: a build's "summary-0" is not the host's "summary-0".
            id: `span:${item.id}`,
            title: item.title,
            summary: item.summary || null,
            category: item.category,
            pr: item.pr ?? null,
          },
        ]
      : [],
  );
  const seen = new Set([...data.items, ...(data.rest ?? [])].map((item) => titleKey(item.title)));
  const extra = spanned.filter((item) => {
    const key = titleKey(item.title);
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
  if (extra.length === 0) return data;
  const rest = [...(data.rest ?? []), ...extra];
  return { ...data, rest, moreCount: rest.length };
}
