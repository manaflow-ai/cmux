// The browse view is the gallery's contact sheet: every card mounts the same real stage iframe
// used by the entry view and matrix runner. It is intentionally a view of the registry rather
// than a second set of synthetic thumbnails, so a card is useful for both visual scanning and
// opening the exact entry/variant that produced it.
import { useEffect, useMemo, useState } from "react";
import type { GalleryEnv } from "../env";
import type { GalleryEntry } from "../format";
import {
  browseFrameHref,
  filterBrowseItems,
  nextBrowseVariant,
  resolveBrowseVariant,
  type BrowseState,
} from "./browseModel";
import { Stage } from "./Stage";

export function BrowseView({
  entries,
  env,
  tune,
  browse,
  onBrowseChange,
  onOpen,
  hrefFor,
}: {
  entries: readonly GalleryEntry[];
  env: GalleryEnv;
  tune: string;
  browse: BrowseState;
  onBrowseChange: (browse: BrowseState, replace?: boolean) => void;
  onOpen: (entry: GalleryEntry, variant: string) => void;
  hrefFor: (entry: GalleryEntry, variant: string) => string;
}) {
  const items = useMemo(
    () => filterBrowseItems(entries, browse.filter, browse.kind, browse.mode, browse.picks),
    [entries, browse.filter, browse.kind, browse.mode, browse.picks],
  );
  const allCount = useMemo(
    () => filterBrowseItems(entries, "", browse.kind, browse.mode, browse.picks).length,
    [entries, browse.kind, browse.mode, browse.picks],
  );
  const allVariants = browse.mode === "variants";
  return (
    <section className="gallery-browse" aria-labelledby="gallery-browse-title">
      <header className="gallery-browse-header">
        <div>
          <h1 id="gallery-browse-title">Browse gallery</h1>
          <p>
            {items.length} of {allCount} live previews, each rendered by its real host. Scan the contact sheet, switch
            variants, or show every state side by side before opening a full view.
          </p>
        </div>
        <div className="gallery-browse-tools">
          <label className="gallery-browse-filter">
            Filter previews
            <input
              type="search"
              value={browse.filter}
              placeholder={`Filter ${allCount} previews`}
              aria-label="Filter gallery previews"
              onChange={(event) => onBrowseChange({ ...browse, filter: event.target.value }, true)}
            />
          </label>
          <fieldset className="gallery-browse-kind-filter">
            <legend>Show</legend>
            {(
              [
                ["all", "All"],
                ["static", "Static"],
                ["motion", "Motion"],
              ] as const
            ).map(([value, label]) => (
              <button
                key={value}
                type="button"
                aria-label={`Show ${label.toLowerCase()} previews`}
                aria-pressed={browse.kind === value}
                onClick={() => onBrowseChange({ ...browse, kind: value }, true)}
              >
                {label}
              </button>
            ))}
          </fieldset>
          <fieldset className="gallery-browse-view-filter">
            <legend>Layout</legend>
            {(
              [
                ["entries", "One per entry"],
                ["variants", "All variants"],
              ] as const
            ).map(([value, label]) => (
              <button
                key={value}
                type="button"
                aria-label={`Show ${label.toLowerCase()}`}
                aria-pressed={browse.mode === value}
                onClick={() => {
                  onBrowseChange({ ...browse, mode: value, cycle: value === "variants" ? false : browse.cycle }, true);
                }}
              >
                {label}
              </button>
            ))}
          </fieldset>
          <label className="gallery-browse-cycle">
            <input
              type="checkbox"
              aria-label="Cycle previews"
              checked={browse.cycle}
              disabled={allVariants}
              onChange={(event) => onBrowseChange({ ...browse, cycle: event.target.checked }, true)}
            />
            Cycle previews
          </label>
        </div>
      </header>
      {items.length ? (
        <div className="gallery-browse-grid">
          {items.map(({ entry, variant }) => (
            <BrowseCard
              key={`${entry.id}:${variant}`}
              entry={entry}
              initialVariant={variant}
              filter={browse.filter}
              kind={browse.kind}
              env={env}
              tune={tune}
              onOpen={onOpen}
              hrefFor={hrefFor}
              onPick={(entryId, variant) =>
                onBrowseChange({ ...browse, picks: { ...browse.picks, [entryId]: variant } }, true)
              }
              cycle={allVariants ? false : browse.cycle}
              variantOnly={allVariants}
            />
          ))}
        </div>
      ) : (
        <div className="gallery-empty">
          <p>
            {browse.filter.trim() ? `No previews match “${browse.filter.trim()}”.` : "No ready entries to preview yet."}
          </p>
          {browse.filter.trim() && (
            <button type="button" onClick={() => onBrowseChange({ ...browse, filter: "" }, true)}>
              Clear filter
            </button>
          )}
        </div>
      )}
    </section>
  );
}

function BrowseCard({
  entry,
  initialVariant,
  filter,
  kind,
  env,
  tune,
  onOpen,
  hrefFor,
  onPick,
  cycle,
  variantOnly,
}: {
  entry: GalleryEntry;
  initialVariant: string;
  filter: string;
  kind: BrowseState["kind"];
  env: GalleryEnv;
  tune: string;
  onOpen: (entry: GalleryEntry, variant: string) => void;
  hrefFor: (entry: GalleryEntry, variant: string) => string;
  onPick: (entryId: string, variant: string) => void;
  cycle: boolean;
  variantOnly: boolean;
}) {
  const [variant, setVariant] = useState(initialVariant);
  const [width, setWidth] = useState(420);
  const [previewNode, setPreviewNode] = useState<HTMLElement | null>(null);
  useEffect(() => {
    if (!previewNode) return;
    const measure = () => setWidth(previewNode.clientWidth);
    measure();
    if (typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(measure);
    observer.observe(previewNode);
    return () => observer.disconnect();
  }, [previewNode]);
  const variants = useMemo(
    () =>
      Object.keys(entry.variants).filter(
        (name) => kind === "all" || Boolean(entry.variants[name]?.play) === (kind === "motion"),
      ),
    [entry, kind],
  );
  const selectedVariant = resolveBrowseVariant(variant, initialVariant, variants);
  const fixture = selectedVariant ? entry.variants[selectedVariant] : undefined;
  // A query can choose a different variant on the same card; registry refreshes keep the current state.
  useEffect(() => {
    setVariant(initialVariant);
    // The query is the reset boundary. An entry refresh may change initialVariant while preserving selection.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [filter]);
  useEffect(() => {
    if (selectedVariant && selectedVariant !== variant) setVariant(selectedVariant);
  }, [selectedVariant, variant]);
  useEffect(() => {
    if (!cycle || variants.length < 2 || env.reducedMotion) return;
    const timer = window.setInterval(() => {
      setVariant((current) => {
        const next = nextBrowseVariant(current, variants) ?? current;
        if (next !== current) onPick(entry.id, next);
        return next;
      });
    }, 2600);
    return () => window.clearInterval(timer);
  }, [cycle, env.reducedMotion, entry.id, onPick, variants]);
  return (
    <article className="gallery-browse-card" data-gallery-browse-entry={entry.id}>
      <header className="gallery-browse-card-header">
        <div>
          <h2>{entry.title}</h2>
          <code>{entry.id}</code>
        </div>
        <span className="gallery-browse-kind">
          {variantOnly && `${selectedVariant} · `}
          {fixture?.play ? "Motion" : "Static"}
        </span>
      </header>
      {fixture?.note && <p className="gallery-browse-card-note">{fixture.note}</p>}
      {!variantOnly && (
        <fieldset className="gallery-browse-variants" aria-label={`${entry.title} variants`}>
          {variants.map((name) => (
            <button
              key={name}
              type="button"
              aria-pressed={name === selectedVariant}
              className={name === selectedVariant ? "active" : undefined}
              onClick={() => {
                setVariant(name);
                onPick(entry.id, name);
              }}
            >
              {name}
            </button>
          ))}
          {variants.length > 1 && (
            <span className="gallery-browse-cycle-note">{cycle && !env.reducedMotion ? "cycling" : "multi-state"}</span>
          )}
        </fieldset>
      )}
      <div ref={setPreviewNode} className="gallery-browse-preview">
        {selectedVariant ? (
          <Stage
            key={selectedVariant}
            entry={entry}
            state={selectedVariant}
            env={env}
            tune={tune}
            available={{ width, height: Number.POSITIVE_INFINITY }}
            thumbnail
          />
        ) : (
          <p className="gallery-empty">No variants available.</p>
        )}
      </div>
      <footer className="gallery-browse-card-footer">
        <a
          href={hrefFor(entry, selectedVariant ?? initialVariant)}
          onClick={(event) => {
            event.preventDefault();
            if (selectedVariant) onOpen(entry, selectedVariant);
          }}
        >
          Open full view
        </a>
        <a href={browseFrameHref(entry, selectedVariant ?? initialVariant, env, tune)} target="_blank" rel="noreferrer">
          Open frame
        </a>
      </footer>
    </article>
  );
}
