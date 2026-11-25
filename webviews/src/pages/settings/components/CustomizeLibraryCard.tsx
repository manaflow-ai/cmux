// Appearance > Customization Library (cmux-customize `library.rs`). Leo, 2026-11-14: "for
// customization i wonder if there's good ways to have like an accumulated collection of those
// things". Everything the person applies (an ask, a profile, a kept try-on, an import) is saved as
// one entry; entries stack top first, each turns on and off, and where two that are on set the same
// key or file, the higher one wins. The engine owns the stack, the rule and every write; this card
// lists `cmux customize library` and runs its verbs (on, off, order, remove) through the host's
// bundled CLI, so the card and the CLI never differ. The list is read with the section
// (sectionQueries) and answered again by each change; it does not poll. Opened at this card by
// `#/settings/appearance?focus=card.customizeLibrary`.
//
// A `pr-N` entry (`cmux customize use pr:N`) is an unmerged pull request's web layer on this app:
// its row names the PR (number, title, short head, a link to it), what it cannot carry ("Needs a
// build: ..."), and the last refresh's word on it (why it turned off). Leo, 2026-11-14: "I want
// people to not accidentally soft lock themselves and like have good recovery options". Its switch
// and Remove run the same CLI verbs through the host as every other entry, never anything the
// experiment serves, and the sidebar's "N experiments on" mark (native, so a broken layer cannot
// take it down) opens this card and turns them off too.
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { Fragment, memo, useContext, useId, useLayoutEffect, useMemo, useRef, useState } from "react";
import { useStableHandlers } from "../../../agent-session/acpmux/stableHandlers";
import { Button } from "../../../ui/Button";
import { CardBusy, useCardWindow, windowGap, type CardWindow } from "../cardWindow";
import { useStore } from "../context";
import {
  beatenByEntry,
  beatenLine,
  entryDetail,
  sourceLabel,
  step,
  type Beaten,
  codeCanTurnOn,
  codeTitle,
  prUrl,
  shortSha,
} from "../customizeLibrary";
import { Switch } from "../editors/ToggleEditor";
import { Icon } from "../icons";
import type { LibraryEntry, LibraryListing, LibraryRun, LibraryCode } from "../ops";
import { LIBRARY_KEY, libraryQuery, STANDUP_KEY, type LibraryRead } from "../sectionQueries";
import { t } from "../strings";
import { focusRoute } from "../../../ui/focusRoute";
import { WithFacts } from "../../../agent-session/acpmux/chips/FactsHoverCard";

/** How the list draws (gallery `settings.customize-library-layouts`). `layers`, the shipped one, is
 * the stack itself: one Settings row per entry, top first, with its switch and its order. `cards` is
 * a grid of swatch tiles; `table` is one dense line per entry. */
export type LibraryLayout = "layers" | "cards" | "table";

/** The page's gestures on one entry. */
export type LibraryActions = {
  onToggle: (name: string, on: boolean) => void;
  onMove: (name: string, position: string) => void;
  onRemove: (name: string) => void;
};

export function CustomizeLibraryCard({ reveal = false }: { reveal?: boolean }) {
  const store = useStore();
  const queryClient = useQueryClient();
  const query = useQuery(libraryQuery(store));
  const [busy, setBusy] = useState(false);
  const [refusal, setRefusal] = useState<string | null>(null);
  const [removing, setRemoving] = useState<string | null>(null);
  const read = query.data ?? null;
  // The store never rejects (a failed call answers a refusal), so the busy state always ends. A list
  // read still on its way (a revisit past the section's fresh time reads again in the background)
  // saw the library before this change: it is dropped before the change runs and again before the
  // change's answer draws, so a late, older listing never draws over the change.
  // (cancelQueries never rejects.)
  const run = (change: LibraryRun) => {
    setBusy(true);
    setRefusal(null);
    return queryClient
      .cancelQueries({ queryKey: LIBRARY_KEY })
      .then(() => store.customizeLibrary(change))
      .then(async (answer) => {
        await queryClient.cancelQueries({ queryKey: LIBRARY_KEY });
        if (answer.library)
          queryClient.setQueryData<LibraryRead>(LIBRARY_KEY, { library: answer.library, refusal: null });
        setRefusal(answer.refusal);
        // The Standup panel shares this library's words and must not retain the pre-change report.
        void queryClient.invalidateQueries({ queryKey: STANDUP_KEY });
      })
      .finally(() => {
        setBusy(false);
        setRemoving(null);
      });
  };
  // One function per gesture for every render: a memo row draws again only when its own props change.
  const handlers = useStableHandlers({
    onToggle: (name: string, on: boolean) => void run({ verb: on ? "on" : "off", name }),
    onMove: (name: string, position: string) => void run({ verb: "order", name, position }),
    onRemove: (name: string) => setRemoving(name),
  });
  const { onToggle, onMove, onRemove } = handlers;
  const actions = useMemo<LibraryActions>(() => ({ onToggle, onMove, onRemove }), [onToggle, onMove, onRemove]);
  // Opt-in (Leo, 2026-11-15: "these are opt-in settings"): nothing draws until the person has
  // applied something. An empty library, or a host with no CLI, shows no card; a CLI that answers
  // with a refusal does, so a library that can't be read says why.
  const listed = read?.library ?? null;
  if (!query.isFetched || (!read?.refusal && (listed === null || listed.entries.length === 0))) return null;
  return (
    <CustomizeLibraryView
      listing={read?.library ?? null}
      drawn={query.isFetched}
      readRefusal={read?.refusal ?? null}
      refusal={refusal}
      busy={busy}
      removing={removing}
      reveal={reveal}
      actions={actions}
      onConfirmRemove={(name) => void run({ verb: "remove", name })}
      onCancelRemove={() => setRemoving(null)}
    />
  );
}

/** The card as it draws, from the listing: the gallery draws it with fixtures. */
export function CustomizeLibraryView({
  listing,
  drawn = true,
  readRefusal = null,
  refusal = null,
  busy = false,
  removing = null,
  reveal = false,
  layout = "layers",
  actions,
  onConfirmRemove,
  onCancelRemove,
}: {
  listing: LibraryListing | null;
  drawn?: boolean;
  readRefusal?: string | null;
  refusal?: string | null;
  busy?: boolean;
  removing?: string | null;
  /** The route opens the page on this card: it scrolls to the card once drawn. */
  reveal?: boolean;
  layout?: LibraryLayout;
  actions: LibraryActions;
  onConfirmRemove: (name: string) => void;
  onCancelRemove: () => void;
}) {
  const entries = useKeptEntries(listing);
  const beaten = useBeaten(listing);
  const keys = useMemo(() => entries.map((entry) => entry.name), [entries]);
  // A grid of tiles (`cards`, the gallery's) draws every entry; the shipped rows are windowed. The
  // entry Remove asked about stays mounted while its confirmation is open.
  const kept = useMemo(() => new Set(removing ? [removing] : []), [removing]);
  const rowWindow = useCardWindow(
    keys,
    LIBRARY_ESTIMATE,
    (index) => String(beaten.get(entries[index]?.name ?? "")?.length ?? 0),
    kept,
  );
  const windowed = layout !== "cards";
  const listing_ = listing !== null && entries.length > 0;
  const confirmTitle = removing ? t("settingsPage.customizeLibrary.removeTitle", removing) : "";
  const card = useRef<HTMLElement>(null);
  const confirm = useRef<HTMLDivElement>(null);
  // The route's reveal waits for the window (cardWindow.ts `ready`): before it, the rows' room is not
  // drawn and the window's start would move the page back. A grid of tiles has no window.
  const ready = !windowed || rowWindow.ready;
  useLayoutEffect(() => {
    if (reveal && ready) card.current?.scrollIntoView?.({ block: "start" });
  }, [reveal, ready]);
  // The confirmation draws under the whole list, so with many entries it opens screens below the row
  // its Remove was on: it scrolls into view and takes focus on Cancel, the safe answer.
  useLayoutEffect(() => {
    if (!removing) return;
    confirm.current?.scrollIntoView?.({ block: "nearest" });
    focusRoute(
      confirm.current?.querySelector<HTMLButtonElement>('[data-library-action="cancel"]'),
      "person",
      "the person's Remove opened the confirmation: Cancel",
    );
  }, [removing]);
  return (
    <section
      className="group"
      data-card="customizeLibrary"
      data-library-layout={layout}
      id="customize-library"
      ref={card}
    >
      <h3 className="group-title">{t("settingsPage.customizeLibrary.title")}</h3>
      <div
        className="rows"
        ref={windowed ? rowWindow.list : undefined}
        role={listing_ && windowed ? "list" : undefined}
        style={windowed ? { paddingBottom: rowWindow.padBottom } : undefined}
        onFocus={windowed ? rowWindow.onFocus : undefined}
        onBlur={windowed ? rowWindow.onBlur : undefined}
      >
        {drawn && listing === null ? (
          <div className="row" data-library-unavailable="">
            <span className="row-help">{readRefusal ?? t("settingsPage.customizeLibrary.unavailable")}</span>
          </div>
        ) : drawn && entries.length === 0 ? (
          <div className="row" data-library-empty="">
            <span className="row-help">{t("settingsPage.customizeLibrary.empty")}</span>
          </div>
        ) : listing ? (
          <>
            <div className="row" data-library-help="">
              <span className="row-help">{t("settingsPage.customizeLibrary.help")}</span>
            </div>
            <LibraryList
              listing={listing}
              entries={entries}
              beaten={beaten}
              layout={layout}
              busy={busy}
              actions={actions}
              rowWindow={windowed ? rowWindow : undefined}
            />
          </>
        ) : null}
      </div>
      {removing && (
        // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
        <div className="accounts-form" data-library-confirm="" role="group" aria-label={confirmTitle} ref={confirm}>
          <div className="row-title">{confirmTitle}</div>
          <div className="row-help">{t("settingsPage.customizeLibrary.removeBody")}</div>
          <div className="accounts-buttons">
            <Button
              danger
              variant="ghost"
              className="button"
              data-library-action="confirmRemove"
              disabled={busy}
              onClick={() => onConfirmRemove(removing)}
            >
              {t("settingsPage.remove")}
            </Button>
            <Button className="button" data-library-action="cancel" onClick={onCancelRemove}>
              {t("settingsPage.cancel")}
            </Button>
          </div>
        </div>
      )}
      {refusal && (
        <div className="row-error" role="alert" data-library-refusal="">
          {t("settingsPage.customizeLibrary.refused", refusal)}
        </div>
      )}
    </section>
  );
}

/** The listing's entries, each equal to the one the last listing had under its name replaced by
 * that one: every change answers a whole new listing, and a memo row whose entry did not change
 * skips it. */
function useKeptEntries(listing: LibraryListing | null): LibraryEntry[] {
  const [kept, setKept] = useState(() => ({ listing, entries: listing?.entries ?? [] }));
  if (kept.listing === listing) return kept.entries;
  const held = new Map(kept.entries.map((entry) => [entry.name, entry]));
  const entries = (listing?.entries ?? []).map((entry) => {
    const old = held.get(entry.name);
    return old && JSON.stringify(old) === JSON.stringify(entry) ? old : entry;
  });
  setKept({ listing, entries });
  return entries;
}

/** An entry row's height before one is measured (name, detail; a line per entry that wins over it). */
const LIBRARY_ESTIMATE = 72;
const NO_BEATEN: Beaten[] = [];

/** Which higher entries win over each entry, built once per listing; an entry whose losses did not
 * change keeps its array, so its memo row skips the new listing. */
function useBeaten(listing: LibraryListing | null): Map<string, Beaten[]> {
  const [kept, setKept] = useState<{ listing: LibraryListing | null; beaten: Map<string, Beaten[]> }>(() => ({
    listing,
    beaten: listing ? beatenByEntry(listing) : new Map(),
  }));
  if (kept.listing === listing) return kept.beaten;
  const next = listing ? beatenByEntry(listing) : new Map<string, Beaten[]>();
  for (const [name, list] of next) {
    const old = kept.beaten.get(name);
    if (old && sameBeaten(old, list)) next.set(name, old);
  }
  setKept({ listing, beaten: next });
  return next;
}

function sameBeaten(a: readonly Beaten[], b: readonly Beaten[]): boolean {
  return (
    a.length === b.length &&
    a.every(
      (one, index) =>
        one.winner === b[index]!.winner &&
        one.keys.length === b[index]!.keys.length &&
        one.keys.every((key, at) => key === b[index]!.keys[at]),
    )
  );
}

/** Every entry, top first, in `layout`. With `rowWindow` (the card's rows), only the entries near the
 * viewport mount; without (the tiles, the gallery), every entry. */
export function LibraryList({
  listing,
  entries,
  beaten,
  layout,
  busy,
  actions,
  rowWindow,
}: {
  listing: LibraryListing;
  /** The listing's entries with the unchanged ones kept (the card); default the listing's own. */
  entries?: LibraryEntry[];
  beaten?: Map<string, Beaten[]>;
  layout: LibraryLayout;
  busy: boolean;
  actions: LibraryActions;
  rowWindow?: CardWindow;
}) {
  const losses = beaten ?? beatenByEntry(listing);
  const shown = entries ?? listing.entries;
  const count = shown.length;
  const items = rowWindow?.items ?? shown.map((entry, index) => ({ index, key: entry.name, gap: 0 }));
  const rows = items.map(({ index, key, gap }) => {
    const entry = shown[index]!;
    return (
      <Fragment key={key}>
        {windowGap(gap)}
        <LibraryEntryRow
          entry={entry}
          beaten={losses.get(entry.name) ?? NO_BEATEN}
          count={count}
          index={index}
          layout={layout}
          actions={actions}
          measure={rowWindow?.measure}
        />
      </Fragment>
    );
  });
  return (
    <CardBusy.Provider value={busy}>
      {layout === "cards" ? <div className="library-grid">{rows}</div> : rows}
    </CardBusy.Provider>
  );
}

/** One entry: its look (swatches), its name, what asked for it and what it sets, which higher entry
 * wins over it and on what, its order and its switch. */
export const LibraryEntryRow = memo(function LibraryEntryRow({
  entry,
  beaten,
  count,
  index,
  layout,
  actions,
  measure,
}: {
  entry: LibraryEntry;
  beaten: Beaten[];
  count: number;
  /** The entry's place in the whole list (0 is the top), for the window and screen readers. */
  index: number;
  layout: LibraryLayout;
  actions: LibraryActions;
  measure?: (node: HTMLElement | null) => void;
}) {
  const labelId = useId();
  const up = step(entry, count, -1);
  const down = step(entry, count, 1);
  const order = (
    <span className="library-order">
      <EntryButton
        icon="chevron"
        iconClass="icon-up"
        action={t("settingsPage.moveUp")}
        entry={entry.name}
        data="up"
        disabled={up === null}
        onClick={() => up && actions.onMove(entry.name, up)}
      />
      <EntryButton
        icon="chevron"
        action={t("settingsPage.moveDown")}
        entry={entry.name}
        data="down"
        disabled={down === null}
        onClick={() => down && actions.onMove(entry.name, down)}
      />
      <EntryButton
        icon="xmark"
        action={t("settingsPage.remove")}
        entry={entry.name}
        data="remove"
        onClick={() => actions.onRemove(entry.name)}
      />
    </span>
  );
  const code = entry.code ?? null;
  const title = code ? codeTitle(code) : entry.name;
  // A PR with no web part has nothing a running app can take: it stays off (its lines say why), and
  // one that is on can always be turned off.
  const stuckOff = code !== null && !entry.on && !codeCanTurnOn(code);
  const toggle = (
    <EntrySwitch
      checked={entry.on}
      disabled={stuckOff}
      labelId={labelId}
      onToggle={(next) => actions.onToggle(entry.name, next)}
    />
  );
  const lines = beaten.map((one) => (
    <div className="row-help library-beaten" data-library-beaten={one.winner} key={one.winner}>
      {beatenLine(one)}
    </div>
  ));
  const shared = {
    ref: measure,
    "data-index": index,
    role: layout === "cards" ? undefined : "listitem",
    "aria-posinset": layout === "cards" ? undefined : index + 1,
    "aria-setsize": layout === "cards" ? undefined : count,
    "data-library-entry": entry.name,
    "data-on": entry.on ? "" : undefined,
    "data-overridden": beaten.length > 0 ? "" : undefined,
    "data-library-code": code ? String(code.pr) : undefined,
  };
  if (layout === "cards") {
    return (
      <div className="library-tile" {...shared}>
        <LibrarySwatches entry={entry} wide />
        <div className="library-tile-head">
          <span className="row-title" id={labelId}>
            {title}
          </span>
          {toggle}
        </div>
        <EntryDetail entry={entry} />
        {lines}
        {order}
      </div>
    );
  }
  if (layout === "table") {
    return (
      <WithFacts facts={[{ value: entryDetail(entry) }]}>
        {(facts) => (
          <div {...facts} className="row library-line" {...shared}>
            <div className="row-main">
              <span className="library-position row-help">{entry.position}</span>
              <LibrarySwatches entry={entry} />
              <span className="row-label">
                <span className="row-title" id={labelId}>
                  {title}
                </span>
                <span className="row-help"> · {sourceLabel(entry.source)}</span>
                {beaten.length > 0 && <span className="row-help library-beaten"> · {beatenLine(beaten[0]!)}</span>}
              </span>
              <span className="row-control library-controls">
                {order}
                {toggle}
              </span>
            </div>
          </div>
        )}
      </WithFacts>
    );
  }
  return (
    <div className="row library-layer" {...shared}>
      <div className="row-main">
        <LibrarySwatches entry={entry} />
        <div className="row-label">
          <div className="row-title" id={labelId}>
            {title}
          </div>
          <EntryDetail entry={entry} />
          {lines}
        </div>
        <span className="row-control library-controls">
          {order}
          {toggle}
        </span>
      </div>
    </div>
  );
});

/** The entry at a glance: the colors it sets (no capture: the engine's thumbnail is its swatches
 * and keys), the layers mark when it sets no color, or the flask for a PR's code. */
function LibrarySwatches({ entry, wide = false }: { entry: LibraryEntry; wide?: boolean }) {
  const swatches = entry.code ? [] : entry.thumbnail.swatches.slice(0, wide ? 6 : 3);
  if (swatches.length === 0) {
    return (
      <span className="library-mark" data-wide={wide ? "" : undefined} aria-hidden="true">
        <Icon name={entry.code ? "flask" : "layers"} />
      </span>
    );
  }
  return (
    <span className="library-mark" data-wide={wide ? "" : undefined} aria-hidden="true">
      {swatches.map((color, index) => (
        <span className="library-swatch" key={`${color}-${index}`} style={{ background: color }} />
      ))}
    </span>
  );
}

/** The line under an entry's title: what asked for it and what it sets, or for a PR entry where it
 * comes from, its short head and a link to the PR, then what needs a build and the last refresh's
 * note. */
function EntryDetail({ entry }: { entry: LibraryEntry }) {
  if (!entry.code) return <div className="row-help library-detail selectable">{entryDetail(entry)}</div>;
  return <CodeLines code={entry.code} />;
}

/** A PR entry's lines. The note is the CLI's own words ("merged: in your build", "no longer
 * applies: ..."), shown as it says them, as a refusal is. */
function CodeLines({ code }: { code: LibraryCode }) {
  return (
    <>
      <div className="row-help library-detail">
        <span className="selectable">{code.repo}</span>
        {" · "}
        <span className="font-mono selectable" data-library-head="">
          {shortSha(code.head)}
        </span>
        {" · "}
        <a href={prUrl(code)} className="channel-link" data-library-pr-link={code.pr}>
          {t("settingsPage.customizeLibrary.code.openPr")}
        </a>
      </div>
      {(code.needs_build ?? []).map((line) => (
        <div className="row-help library-needs-build selectable" data-library-needs-build="" key={line}>
          {t("settingsPage.customizeLibrary.code.needsBuild", line)}
        </div>
      ))}
      {code.note && (
        <div className="row-help library-note selectable" data-library-note="">
          {code.note}
        </div>
      )}
    </>
  );
}

function EntrySwitch({
  disabled,
  ...props
}: {
  checked: boolean;
  disabled?: boolean;
  labelId: string;
  onToggle: (on: boolean) => void;
}) {
  const busy = useContext(CardBusy);
  return <Switch {...props} disabled={busy || disabled === true} />;
}

function EntryButton({
  icon,
  iconClass,
  action,
  entry,
  data,
  disabled,
  onClick,
}: {
  icon: string;
  iconClass?: string;
  action: string;
  entry: string;
  data: string;
  disabled?: boolean;
  onClick: () => void;
}) {
  const busy = useContext(CardBusy);
  return (
    <Button
      variant="ghost"
      size="sm"
      icon
      type="button"
      className="icon-button"
      aria-label={`${action}: ${entry}`}
      title={action}
      disabled={disabled || busy}
      data-library-action={data}
      onClick={onClick}
    >
      <Icon name={icon} className={iconClass} />
    </Button>
  );
}
