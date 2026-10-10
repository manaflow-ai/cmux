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
  type BrowseKind,
} from "./browseModel";
import { Stage } from "./Stage";

export function BrowseView({
  entries,
  env,
  tune,
  onOpen,
  hrefFor,
}: {
  entries: readonly GalleryEntry[];
  env: GalleryEnv;
  tune: string;
  onOpen: (entry: GalleryEntry, variant: string) => void;
  hrefFor: (entry: GalleryEntry, variant: string) => string;
}) {
  const [filter, setFilter] = useState("");
  const [kind, setKind] = useState<BrowseKind>("all");
  const [cycle, setCycle] = useState(false);
  const items = useMemo(() => filterBrowseItems(entries, filter, kind), [entries, filter, kind]);
  const allCount = useMemo(() => filterBrowseItems(entries, "").length, [entries]);
  return (
    <section className="gallery-browse" aria-labelledby="gallery-browse-title">
      <header className="gallery-browse-header">
        <div>
          <h1 id="gallery-browse-title">Browse gallery</h1>
          <p>
            {items.length} of {allCount} live previews, each rendered by its real host. Scan the contact sheet, switch
            variants, or cycle multi-state previews before opening a full view.
          </p>
        </div>
        <div className="gallery-browse-tools">
          <label className="gallery-browse-filter">
            Filter previews
            <input
              type="search"
              value={filter}
              placeholder={`Filter ${allCount} previews`}
              aria-label="Filter gallery previews"
              onChange={(event) => setFilter(event.target.value)}
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
                aria-pressed={kind === value}
                onClick={() => setKind(value)}
              >
                {label}
              </button>
            ))}
          </fieldset>
          <label className="gallery-browse-cycle">
            <input
              type="checkbox"
              aria-label="Cycle previews"
              checked={cycle}
              onChange={(event) => setCycle(event.target.checked)}
            />
            Cycle previews
          </label>
        </div>
      </header>
      {items.length ? (
        <div className="gallery-browse-grid">
          {items.map(({ entry, variant }) => (
            <BrowseCard
              key={entry.id}
              entry={entry}
              initialVariant={variant}
              env={env}
              tune={tune}
              onOpen={onOpen}
              hrefFor={hrefFor}
              cycle={cycle}
            />
          ))}
        </div>
      ) : (
        <div className="gallery-empty">
          <p>{filter.trim() ? `No previews match “${filter.trim()}”.` : "No ready entries to preview yet."}</p>
          {filter.trim() && (
            <button type="button" onClick={() => setFilter("")}>
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
  env,
  tune,
  onOpen,
  hrefFor,
  cycle,
}: {
  entry: GalleryEntry;
  initialVariant: string;
  env: GalleryEnv;
  tune: string;
  onOpen: (entry: GalleryEntry, variant: string) => void;
  hrefFor: (entry: GalleryEntry, variant: string) => string;
  cycle: boolean;
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
  const variants = useMemo(() => Object.keys(entry.variants), [entry]);
  const selectedVariant = resolveBrowseVariant(variant, initialVariant, variants);
  const fixture = selectedVariant ? entry.variants[selectedVariant] : undefined;
  useEffect(() => {
    if (selectedVariant && selectedVariant !== variant) setVariant(selectedVariant);
  }, [selectedVariant, variant]);
  useEffect(() => {
    if (!cycle || variants.length < 2 || env.reducedMotion) return;
    const timer = window.setInterval(() => {
      setVariant((current) => {
        return nextBrowseVariant(current, variants) ?? current;
      });
    }, 2600);
    return () => window.clearInterval(timer);
  }, [cycle, env.reducedMotion, variants]);
  return (
    <article className="gallery-browse-card" data-gallery-browse-entry={entry.id}>
      <header className="gallery-browse-card-header">
        <div>
          <h2>{entry.title}</h2>
          <code>{entry.id}</code>
        </div>
        <span className="gallery-browse-kind">{fixture?.play ? "Motion" : "Static"}</span>
      </header>
      <fieldset className="gallery-browse-variants" aria-label={`${entry.title} variants`}>
        {variants.map((name) => (
          <button
            key={name}
            type="button"
            aria-pressed={name === selectedVariant}
            className={name === selectedVariant ? "active" : undefined}
            onClick={() => setVariant(name)}
          >
            {name}
          </button>
        ))}
        {variants.length > 1 && (
          <span className="gallery-browse-cycle-note">{cycle && !env.reducedMotion ? "cycling" : "multi-state"}</span>
        )}
      </fieldset>
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
