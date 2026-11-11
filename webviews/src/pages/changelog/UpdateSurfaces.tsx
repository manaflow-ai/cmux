// The update surfaces of the What's New system (cx-urd.61, Lawrence picked card A and popover A,
// 2026-10-11), in the same tokens and type steps as the changelog page:
//  - UpdatedCard (after an update, the sidebar's bottom card slot): the theme's surface (Leo
//    2026-11-02: "why is the update thing unthemed"; the sidebar's CardSurfaceView.takesThemeTint). Short (Lawrence 2026-10-31, msg 19218: "it looks like too much
//    text"; picked from cmux-shots/whatsnew-variations): "Updated to Nightly", the update's one top
//    change ("Sidebar: …", the first area's first change, updateSummary.ts) and What's New.
//    Since 2026-11-07 (Leo: "the border styles, the glass intensity is different ... the heights
//    never match up with anything") it is the composer's twin: the composer's material
//    (ui/glass/composerMaterial.css) and its one-line height, with "Updated to Nightly · What's
//    New ↗" on one line over the change, and resting on it opens a scrollable preview of the
//    update's changes in the same glass (UpdatedCardPreview, updatedPreview.ts).
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
import {
  useCallback,
  useEffect,
  useId,
  useLayoutEffect,
  useRef,
  useState,
  useSyncExternalStore,
  type CSSProperties,
  type MouseEvent,
} from "react";
import { CARD_SCROLL_ATTRIBUTE, installScrollEdges } from "../../scrollers";
import { motionMode } from "../../ui/motion/motionMode";
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
import { PREVIEW_CLOSE_MS, PreviewIntent, previewEntries } from "./updatedPreview";
import { parsePreviewMode, type UpdatedPreviewMode } from "./updatedPreviewMode";
import { pressCard, SHIPPED_DRAG_FEEL, type CardDragFeel, type CardDragHost, type CardRow } from "./updatedCardDrag";
import { PREVIEW_MAX_PX, UpdatedCardPreview, type PreviewLayout, type PreviewTarget } from "./UpdatedCardPreview";
export type { PreviewLayout } from "./UpdatedCardPreview";
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
export function CopyVersion({
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

/** `text` cut at each mark, the marks kept as parts of their own, in the order the text has them. */
function splitAtMarks(text: string, marks: string[]): string[] {
  return marks.reduce<string[]>(
    (parts, mark) => parts.flatMap((part) => part.split(mark).flatMap((piece, i) => (i ? [mark, piece] : [piece]))),
    [text],
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
  const parts = splitAtMarks(strings.format("updates.popover.span", "\u0000", "\u0001"), ["\u0000", "\u0001"]);
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

/** Where the card puts What's New (Leo 2026-11-07: "just update it to Nightly, and then What's New
 * with the up and to the right arrow that you can click as a thing", or "to the very top ... right
 * aligned alongside the close button"): after the title on its line (`title`, shipped), at the far
 * end of the title line before the x (`top-right`), or the old button under the note (`button`,
 * the look before). Gallery variants. */
export type WhatsNewPlacement = "title" | "top-right" | "button";

/** How long the card waits for the host to make room for the open preview before it opens anyway. */
const PREVIEW_ROOM_WAIT_MS = 150;

export function UpdatedCard({
  data,
  span,
  strings,
  actions,
  closeButton = true,
  glass = true,
  decoration,
  animate = true,
  placement = "title",
  previewLayout = "header",
  previewMode,
  previewOpen,
  hostPointer,
  onPreviewSize,
  onPreviewGlass,
  anchor = "bottom",
  drag,
  dragFeel = SHIPPED_DRAG_FEEL,
  notesLoading = false,
  loadingLook = SHIPPED_NOTE_LOADING,
}: {
  data: UpdateHighlights;
  /** The notes of every build after the previous version, newest first; absent until they load. */
  span?: ReleaseNotes[];
  strings: Strings;
  actions: UpdateSurfaceActions;
  /** Draws the x (with `actions.dismiss`); false where the host draws its own (the sidebar's). */
  closeButton?: boolean;
  /** Frosts what is behind the card (a page with content under it, the gallery); false in the
      sidebar, whose card sits on the sidebar's own glass, and with no `.ui-glass` in the document
      the lens draws no wallpaper copy there. */
  glass?: boolean;
  /** The decoration in the card's slot (ThemeDecorations `updated-card`); undefined reads the theme's. */
  decoration?: string | null;
  /** The doodle draws on (false: drawn from the start, for stills). */
  animate?: boolean;
  /** Where What's New sits (gallery variants); `title` ships. */
  placement?: WhatsNewPlacement;
  /** How the open hover preview is laid out (gallery variants); `header` ships. The sidebar host
      draws its x on the card's title line, wherever this layout puts it (SidebarUpdatedCardHost). */
  previewLayout?: PreviewLayout;
  /** Where the card shows the update's changes (updatedPreviewMode.ts); undefined reads the theme's
      (the shipped `beside`: the native host opens them beside the sidebar, the card never grows).
      Only `above` opens the hover preview in the card itself. */
  previewMode?: UpdatedPreviewMode;
  /** Holds the hover preview open or closed (gallery stills); undefined: the pointer decides. */
  previewOpen?: boolean;
  /** Whether the sidebar host has the pointer on the card (its native tracking area); undefined
      until the host says, and then the page's own pointer events decide. */
  hostPointer?: boolean;
  /** The height, CSS px, the card needs above its slot's bottom while the preview is open, 0 once
      it has closed: the host grows its view upward by it, over the list, without moving the list. */
  onPreviewSize?: (height: number) => void;
  /** The height, CSS px, the open preview will have once its motion ends, 0 as it starts to close:
      said as the motion starts, so the host's glass behind the page runs the same motion with it. */
  onPreviewGlass?: (height: number) => void;
  /** Where the card rests: on the bottom slot (its preview opens upward) or at the top of the list
      (its preview opens downward). */
  anchor?: CardRow;
  /** Moves the card while the person drags it (updatedCardDrag.ts); absent: the card does not drag. */
  drag?: CardDragHost;
  dragFeel?: CardDragFeel;
  /** The notes of the update's span are still loading: the title is final, and the change line holds
      its one line with a quiet indicator until the words come (or the load gives up and the host's
      items stand in), so the card never draws blank and the line never jumps. */
  notesLoading?: boolean;
  /** How the loading change line looks (gallery variants); `dots` ships. */
  loadingLook?: NoteLoadingLook;
}) {
  const titleId = useId();
  const [copied, setCopied] = useState(false);
  const themed = useDecoration("updated-card");
  const doodle = (decoration === undefined ? themed : decoration) === "doodle";
  const themedMode = parsePreviewMode(useDecoration("updated-card-preview"));
  const mode = previewMode ?? themedMode;
  const summary = span ? summarizeUpdate(span, strings.language) : summarizeHighlights(readableUpdate(data));
  const top = summary.rows[0];
  const name = /^[^-]+-nightly\.\d+$/.test(data.version) ? strings.t("updates.card.nightly") : data.version;
  const titleKey = data.delivery === "background" ? "updates.card.updatedBehind" : "updates.card.updatedTo";
  const [before, after] = strings.format(titleKey, "\u0000").split("\u0000");
  // Every layout opens and closes on the card's curve, with the host's native glass (Leo 2026-11-08).
  const preview = useHoverPreview({
    data,
    span,
    strings,
    previewOpen,
    hostPointer,
    onPreviewSize,
    onPreviewGlass,
    enabled: !doodle && mode === "above",
    runsHeight: true,
  });
  // A row of the in-card preview opens What's New at its change; the card's own links at the top.
  const openChangelog = (target?: PreviewTarget) => {
    preview.close();
    actions.openChangelog(target);
  };
  const openWhatsNew = () => openChangelog();
  const rest = useRef<HTMLElement | null>(null);
  const dragRef = useCardDrag(rest, drag, dragFeel, preview.closeForDrag);
  const { cardRef } = preview;
  const plainRef = useCallback(
    (element: HTMLElement | null) => {
      cardRef.current = element;
      dragRef(element);
    },
    [cardRef, dragRef],
  );
  // The doodle card has no preview: it is its own rest box, and drags as the plain card does
  // (review F4 of #37790).
  const doodleRef = useCallback(
    (element: HTMLElement | null) => {
      cardRef.current = element;
      rest.current = element;
      dragRef(element);
    },
    [cardRef, dragRef],
  );
  const restRef = useCallback((element: HTMLElement | null) => {
    rest.current = element;
  }, []);
  const whatsNew = (
    <button type="button" className="wn-card-primary" onClick={openWhatsNew}>
      {strings.t("changelog.page.title")}
    </button>
  );
  const title = (
    <div className="wn-card-title" id={titleId}>
      {before}
      <CopyVersion version={data.version} strings={strings} onCopied={setCopied}>
        {name}
      </CopyVersion>
      {after}
      <span aria-live="polite">{copied && ` · ${strings.t("updates.card.copied")}`}</span>
    </div>
  );
  const close = closeButton && actions.dismiss && (
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
  );
  // The card's second line: the top change (the shipped look), the full version (`version`), or See
  // What's New (`quiet`, a card with no list).
  const note =
    mode === "version" && name !== data.version ? (
      <p className="wn-card-version">{data.version}</p>
    ) : mode === "quiet" ? (
      <p className="wn-card-note">
        <button type="button" className="wn-card-seenew" onClick={openWhatsNew}>
          {strings.t("updates.card.seeWhatsNew")}
          <span aria-hidden="true"> ↗</span>
        </button>
      </p>
    ) : notesLoading ? (
      <NoteLoading look={loadingLook} label={strings.t("updates.card.loadingNotes")} />
    ) : (
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
    );
  if (doodle) {
    return (
      <Doodle animate={animate}>
        <section
          className="wn-card"
          aria-labelledby={titleId}
          data-decoration="doodle"
          data-anchor={anchor}
          data-drags={drag ? "" : undefined}
          data-glass={glass ? "" : undefined}
          data-composer-material=""
          ref={doodleRef}
        >
          <DoodleHeadline version={cardVersion(data.version)} strings={strings} />
          {title}
          {close}
          {note}
          <DoodleActions strings={strings} whatsNew={whatsNew} onGotIt={actions.dismiss} />
        </section>
      </Doodle>
    );
  }
  return (
    <section
      className="wn-card wn-updated"
      aria-labelledby={titleId}
      data-placement={placement}
      data-layout={previewLayout}
      data-mode={mode}
      data-anchor={anchor}
      data-drags={drag ? "" : undefined}
      data-preview={preview.shown ? "open" : "closed"}
      data-glass={glass ? "" : undefined}
      data-composer-material=""
      style={{ "--wn-preview-h": `${preview.height}px` } as CSSProperties}
      ref={plainRef}
    >
      {preview.mounted && (
        <UpdatedCardPreview
          entries={preview.entries}
          shown={preview.shown}
          strings={strings}
          bodyRef={preview.bodyRef}
          onOpen={openChangelog}
        />
      )}
      <div className="wn-card-rest" ref={restRef}>
        <div className="wn-card-head">
          {title}
          {/* The shipped title line is the title alone (Lawrence 2026-11-07: "Updated to ..." was cut
              to fit What's New beside it); What's New leads the open preview. */}
          {placement === "top-right" && (
            <button type="button" className="wn-card-link" onClick={openWhatsNew}>
              {strings.t("changelog.page.title")}
              <span aria-hidden="true"> ↗</span>
            </button>
          )}
        </div>
        {close}
        {note}
        {/* Open, the card's second line is the full version, in the note's place and height. */}
        {preview.shown && name !== data.version && <p className="wn-card-version">{data.version}</p>}
        {placement === "button" && <div className="wn-card-actions">{whatsNew}</div>}
      </div>
    </section>
  );
}

/** The loading change line's looks (gallery variants, Leo 2026-11-09: "for the, you know, fixed or
    whatever subtitle text individually, we can have it be, like, should have a loading indicator, like
    an ellipsis-type thing"): three still dots (`dots`, shipped; no breathing loop, test/no-breathing-dots),
    the ellipsis glyph (`glyph`), a bar one line tall that a light crosses (`bar`), and the words
    (`words`). */
export type NoteLoadingLook = "dots" | "glyph" | "bar" | "words";
export const NOTE_LOADING_LOOKS: readonly NoteLoadingLook[] = ["dots", "glyph", "bar", "words"];
export const SHIPPED_NOTE_LOADING: NoteLoadingLook = "dots";

/** The change line while the update's notes load: the note's own box (its font, line height and
    margin), so the words that replace it take exactly its room. VoiceOver reads "Loading what's new"
    (a clipped label); the marks are hidden from it. */
function NoteLoading({ look, label }: { look: NoteLoadingLook; label: string }) {
  return (
    <p className="wn-card-note wn-card-note-loading" data-loading={look}>
      {look === "words" ? (
        `${label}\u2026`
      ) : (
        <>
          <span className="wn-note-label">{label}</span>
          <span aria-hidden="true">
            {look === "bar" ? (
              <span className="wn-note-bar" />
            ) : look === "glyph" ? (
              "\u2026"
            ) : (
              <span className="wn-note-dots">
                <span />
                <span />
                <span />
              </span>
            )}
          </span>
        </>
      )}
    </p>
  );
}

/** Presses on the card start its drag (the section listens itself: it is not a control). Returns the
 *  card's ref: a theme switch between the plain card and the doodle one replaces the card's node, and
 *  the new node takes the listener (review of #38020). */
function useCardDrag(
  rest: { current: HTMLElement | null },
  drag: CardDragHost | undefined,
  feel: CardDragFeel,
  onStart: () => void,
): (element: HTMLElement | null) => void {
  const latest = useRef({ drag, feel, onStart });
  latest.current = { drag, feel, onStart };
  const attached = useRef<{ element: HTMLElement; press: (event: PointerEvent) => void } | null>(null);
  useEffect(
    () => () => {
      attached.current?.element.removeEventListener("pointerdown", attached.current.press);
      attached.current = null;
    },
    [],
  );
  return useCallback(
    (element: HTMLElement | null) => {
      if (attached.current?.element === element) return;
      attached.current?.element.removeEventListener("pointerdown", attached.current.press);
      attached.current = null;
      if (!element) return;
      // A card without a host to drag it ignores the press (`drag` is read at the press).
      const press = (event: PointerEvent) => {
        const { drag, feel, onStart } = latest.current;
        if (drag && rest.current) pressCard(rest.current, event, drag, feel, onStart);
      };
      element.addEventListener("pointerdown", press);
      attached.current = { element, press };
    },
    [rest],
  );
}

/** The hover preview's state: its rows, whether they are mounted (from the first time the pointer
 * reaches the card, so the list is measured before the dwell ends), whether it shows, its height,
 * and the card's pointer and key handlers. */
function useHoverPreview({
  data,
  span,
  strings,
  previewOpen,
  hostPointer,
  onPreviewSize,
  onPreviewGlass,
  enabled,
  runsHeight,
}: {
  data: UpdateHighlights;
  span?: ReleaseNotes[];
  strings: Strings;
  previewOpen?: boolean;
  hostPointer?: boolean;
  onPreviewSize?: (height: number) => void;
  onPreviewGlass?: (height: number) => void;
  enabled: boolean;
  /** The preview opens and closes on a height run (`header-bottom`); else it is simply there. */
  runsHeight: boolean;
}) {
  const entries = enabled ? previewEntries(data, span, strings.language) : [];
  const forced = previewOpen !== undefined;
  const [warm, setWarm] = useState(previewOpen === true);
  const [wanted, setWanted] = useState(false);
  const [shown, setShown] = useState(false);
  const [height, setHeight] = useState(0);
  const list = useRef<HTMLDivElement | null>(null);
  const card = useRef<HTMLElement | null>(null);
  const intent = useRef<PreviewIntent | null>(null);
  intent.current ??= new PreviewIntent(setWanted);
  useEffect(() => () => intent.current?.dispose(), []);
  const sized = useRef(onPreviewSize);
  sized.current = onPreviewSize;
  // The card has asked the host for room it has not handed back yet.
  const asked = useRef(false);
  useEffect(() => {
    if (hostPointer === undefined) return;
    if (hostPointer) setWarm(true);
    intent.current?.host(hostPointer);
  }, [hostPointer]);
  const want = enabled && entries.length > 0 && (forced ? previewOpen : wanted);
  const mounted = enabled && entries.length > 0 && (warm || want);
  // The preview's own height (What's New and the list), measured once it is mounted (it is laid out
  // at its natural height while the preview is closed, clipped to nothing): the preview opens to it,
  // at most PREVIEW_MAX_PX.
  const count = entries.length;
  useLayoutEffect(() => {
    if (!mounted || !list.current) return;
    setHeight(Math.ceil(Math.min(list.current.scrollHeight, PREVIEW_MAX_PX)));
  }, [mounted, count]);
  useLayoutEffect(() => {
    if (!want) {
      setShown(false);
      if (forced || !asked.current) return;
      const handBack = () => {
        asked.current = false;
        sized.current?.(0);
      };
      // With motion reduced or off the preview has no close to run (updateSurfaces.css): the room
      // goes back at once (#37615 F2).
      if (!runsHeight || motionMode() !== "full") {
        handBack();
        return;
      }
      // The glass closes over the rows first; then the host takes its room back.
      const timer = setTimeout(handBack, PREVIEW_CLOSE_MS);
      return () => clearTimeout(timer);
    }
    if (!mounted) {
      setWarm(true);
      return;
    }
    const rest = list.current?.closest(".wn-updated")?.querySelector<HTMLElement>(".wn-card-rest");
    const target = Math.ceil((rest?.getBoundingClientRect().height ?? 0) + height);
    if (forced || !sized.current || height === 0) {
      setShown(height > 0);
      return;
    }
    // The host grows the card's view first; the preview opens once the room is there, so the glass's
    // top edge never runs past the view's (or after a short wait, in case the host cannot grow).
    asked.current = true;
    sized.current(target);
    const view = globalThis.window;
    const roomy = () => !view || view.innerHeight >= target - 1;
    if (roomy()) {
      setShown(true);
      return;
    }
    const open = () => {
      view.removeEventListener("resize", onResize);
      clearTimeout(timer);
      setShown(true);
    };
    const onResize = () => {
      if (roomy()) open();
    };
    view.addEventListener("resize", onResize);
    const timer = setTimeout(open, PREVIEW_ROOM_WAIT_MS);
    return () => {
      view.removeEventListener("resize", onResize);
      clearTimeout(timer);
    };
  }, [want, mounted, height, forced, runsHeight]);
  // The card listens for the pointer and Escape itself (the section is not a control).
  const open = want && shown;
  const isOpen = useRef(open);
  isOpen.current = open;
  const glassed = useRef(onPreviewGlass);
  glassed.current = onPreviewGlass;
  // Said in the same commit that flips `data-preview`, so the host's glass starts with the page's.
  const glass = open ? height : 0;
  useLayoutEffect(() => glassed.current?.(glass), [glass]);
  useEffect(() => {
    const element = card.current;
    if (!element || !enabled) return;
    const enter = () => {
      setWarm(true);
      intent.current?.page(true);
    };
    const leave = () => intent.current?.page(false);
    // Escape closes an open preview first; the card's own Escape (surface.tsx) closes the card. Heard
    // on the document before its bubbling listeners: a preview the hover opened has no focus inside the
    // card, so the key never passes through it (review F2 of #37615).
    const doc = element.ownerDocument;
    const key = (event: KeyboardEvent) => {
      if (event.key !== "Escape" || event.isComposing || !isOpen.current) return;
      event.preventDefault();
      intent.current?.close();
    };
    element.addEventListener("pointerenter", enter);
    element.addEventListener("pointerleave", leave);
    doc.addEventListener("keydown", key, true);
    return () => {
      element.removeEventListener("pointerenter", enter);
      element.removeEventListener("pointerleave", leave);
      doc.removeEventListener("keydown", key, true);
    };
  }, [enabled]);
  return {
    entries,
    mounted,
    shown: open,
    height,
    bodyRef: list,
    cardRef: card,
    close: () => intent.current?.close(),
    /** Closes it for a drag: the room goes back at once, so the host does not shrink the held card's
        view mid-drag when the close ends (review F2 of #37790). */
    closeForDrag: () => {
      if (asked.current) {
        asked.current = false;
        sized.current?.(0);
      }
      intent.current?.close();
    },
  };
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
      <button type="button" className="wn-pop-all" onClick={() => actions.openChangelog()}>
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
        // oxlint-disable-next-line jsx-a11y/no-noninteractive-tabindex -- focus the scroll list to read it with the keys.
        tabIndex={0}
        aria-labelledby={titleId}
        {...{ [CARD_SCROLL_ATTRIBUTE]: "" }}
      >
        {items.length > 0 && (
          <ul className="wn-pop-list">
            {items.map((item) => (
              <PopRow key={item.id} item={item} layout={layout} onOpen={() => actions.openChangelog()} />
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
                      <PopRow key={item.id} item={item} layout={layout} onOpen={() => actions.openChangelog()} />
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
        <button type="button" className="wn-pop-all" onClick={() => actions.openChangelog()}>
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
