// Personalization > Customization Library (cmux-customize `library.rs`). Leo, 2026-11-14: "for
// customization i wonder if there's good ways to have like an accumulated collection of those
// things". Everything the person applies (an ask, a profile, a kept try-on, an import) is saved as
// one entry; entries stack top first, each turns on and off, and where two that are on set the same
// key or file, the higher one wins. The engine owns the stack, the rule and every write; this card
// lists `cmux customize library` and runs its verbs (on, off, order, remove) through the host's
// bundled CLI, so the card and the CLI never differ. The list is read with the section
// (sectionQueries) and answered again by each change; it does not poll. Opened at this card by
// `#/settings/personalization?focus=card.customizeLibrary`.
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useId, useLayoutEffect, useRef, useState } from "react";
import { Button } from "../../../ui/Button";
import { useStore } from "../context";
import { beatenByEntry, beatenLine, entryDetail, sourceLabel, step, type Beaten } from "../customizeLibrary";
import { Switch } from "../editors/ToggleEditor";
import { Icon } from "../icons";
import type { LibraryEntry, LibraryListing, LibraryRun } from "../ops";
import { LIBRARY_KEY, libraryQuery, type LibraryRead } from "../sectionQueries";
import { t } from "../strings";
import { focusRoute } from "../../../ui/focusRoute";

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
      })
      .finally(() => {
        setBusy(false);
        setRemoving(null);
      });
  };
  // Opt-in (Leo, 2026-11-15: "these are opt-in settings"): nothing draws until the person has
  // applied something. An empty library, or a host with no CLI, shows no card; a CLI that answers
  // with a refusal does, so a library that can't be read says why.
  const listed = read?.library ?? null;
  if (!query.isFetched || (!read?.refusal && (listed === null || listed.entries.length === 0))) return null;
  const actions: LibraryActions = {
    onToggle: (name, on) => void run({ verb: on ? "on" : "off", name }),
    onMove: (name, position) => void run({ verb: "order", name, position }),
    onRemove: (name) => setRemoving(name),
  };
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
  const entries = listing?.entries ?? [];
  const confirmTitle = removing ? t("settingsPage.customizeLibrary.removeTitle", removing) : "";
  const card = useRef<HTMLElement>(null);
  const confirm = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    if (reveal) card.current?.scrollIntoView?.({ block: "start" });
  }, [reveal]);
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
      <div className="rows">
        {drawn && listing === null ? (
          <div className="row" data-library-unavailable="">
            <span className="row-help">{readRefusal ?? t("settingsPage.customizeLibrary.unavailable")}</span>
          </div>
        ) : drawn && entries.length === 0 ? (
          <div className="row" data-library-empty="">
            <span className="row-help">{t("settingsPage.customizeLibrary.empty")}</span>
          </div>
        ) : listing ? (
          <LibraryList listing={listing} layout={layout} busy={busy} actions={actions} />
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

/** Every entry, top first, in `layout`. */
export function LibraryList({
  listing,
  layout,
  busy,
  actions,
}: {
  listing: LibraryListing;
  layout: LibraryLayout;
  busy: boolean;
  actions: LibraryActions;
}) {
  const beaten = beatenByEntry(listing);
  const count = listing.entries.length;
  const rows = listing.entries.map((entry) => (
    <LibraryEntryRow
      key={entry.name}
      entry={entry}
      beaten={beaten.get(entry.name) ?? []}
      count={count}
      layout={layout}
      busy={busy}
      actions={actions}
    />
  ));
  return layout === "cards" ? <div className="library-grid">{rows}</div> : <>{rows}</>;
}

/** One entry: its look (swatches), its name, what asked for it and what it sets, which higher entry
 * wins over it and on what, its order and its switch. */
export function LibraryEntryRow({
  entry,
  beaten,
  count,
  layout,
  busy,
  actions,
}: {
  entry: LibraryEntry;
  beaten: Beaten[];
  count: number;
  layout: LibraryLayout;
  busy: boolean;
  actions: LibraryActions;
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
        disabled={busy || up === null}
        onClick={() => up && actions.onMove(entry.name, up)}
      />
      <EntryButton
        icon="chevron"
        action={t("settingsPage.moveDown")}
        entry={entry.name}
        data="down"
        disabled={busy || down === null}
        onClick={() => down && actions.onMove(entry.name, down)}
      />
      <EntryButton
        icon="xmark"
        action={t("settingsPage.remove")}
        entry={entry.name}
        data="remove"
        disabled={busy}
        onClick={() => actions.onRemove(entry.name)}
      />
    </span>
  );
  const toggle = (
    <Switch
      checked={entry.on}
      disabled={busy}
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
    "data-library-entry": entry.name,
    "data-on": entry.on ? "" : undefined,
    "data-overridden": beaten.length > 0 ? "" : undefined,
  };
  if (layout === "cards") {
    return (
      <div className="library-tile" {...shared}>
        <LibrarySwatches entry={entry} wide />
        <div className="library-tile-head">
          <span className="row-title" id={labelId}>
            {entry.name}
          </span>
          {toggle}
        </div>
        <div className="row-help library-detail selectable">{entryDetail(entry)}</div>
        {lines}
        {order}
      </div>
    );
  }
  if (layout === "table") {
    return (
      <div className="row library-line" {...shared} title={entryDetail(entry)}>
        <div className="row-main">
          <span className="library-position row-help">{entry.position}</span>
          <LibrarySwatches entry={entry} />
          <span className="row-label">
            <span className="row-title" id={labelId}>
              {entry.name}
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
    );
  }
  return (
    <div className="row library-layer" {...shared}>
      <div className="row-main">
        <LibrarySwatches entry={entry} />
        <div className="row-label">
          <div className="row-title" id={labelId}>
            {entry.name}
          </div>
          <div className="row-help library-detail selectable">{entryDetail(entry)}</div>
          {lines}
        </div>
        <span className="row-control library-controls">
          {order}
          {toggle}
        </span>
      </div>
    </div>
  );
}

/** The entry at a glance: the colors it sets (no capture: the engine's thumbnail is its swatches
 * and keys), or the layers mark when it sets no color. */
function LibrarySwatches({ entry, wide = false }: { entry: LibraryEntry; wide?: boolean }) {
  const swatches = entry.thumbnail.swatches.slice(0, wide ? 6 : 3);
  if (swatches.length === 0) {
    return (
      <span className="library-mark" data-wide={wide ? "" : undefined} aria-hidden="true">
        <Icon name="layers" />
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
  disabled: boolean;
  onClick: () => void;
}) {
  return (
    <Button
      variant="ghost"
      size="sm"
      icon
      type="button"
      className="icon-button"
      aria-label={`${action}: ${entry}`}
      title={action}
      disabled={disabled}
      data-library-action={data}
      onClick={onClick}
    >
      <Icon name={icon} className={iconClass} />
    </Button>
  );
}
