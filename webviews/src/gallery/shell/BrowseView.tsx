// The browse view is the gallery's contact sheet: every card mounts the same real stage iframe
// used by the entry view and matrix runner. It is intentionally a view of the registry rather
// than a second set of synthetic thumbnails, so a card is useful for both visual scanning and
// opening the exact entry/variant that produced it.
import { useState } from "react";
import type { GalleryEnv } from "../env";
import type { GalleryEntry } from "../format";
import { browseFrameHref, browseItems } from "./browseModel";
import { Stage } from "./Stage";

export function BrowseView({
  entries,
  env,
  tune,
  available,
  onOpen,
  hrefFor,
}: {
  entries: readonly GalleryEntry[];
  env: GalleryEnv;
  tune: string;
  available: { width: number; height: number };
  onOpen: (entry: GalleryEntry, variant: string) => void;
  hrefFor: (entry: GalleryEntry, variant: string) => string;
}) {
  const items = browseItems(entries);
  return (
    <section className="gallery-browse" aria-labelledby="gallery-browse-title">
      <header className="gallery-browse-header">
        <div>
          <h1 id="gallery-browse-title">Browse gallery</h1>
          <p>
            {items.length} live entries, each rendered by its real host. Pick a variant to scan the surface, then open
            it for the full-size view or replay its motion.
          </p>
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
              available={available}
              onOpen={onOpen}
              hrefFor={hrefFor}
            />
          ))}
        </div>
      ) : (
        <p className="gallery-empty">No ready entries to preview yet.</p>
      )}
    </section>
  );
}

function BrowseCard({
  entry,
  initialVariant,
  env,
  tune,
  available,
  onOpen,
  hrefFor,
}: {
  entry: GalleryEntry;
  initialVariant: string;
  env: GalleryEnv;
  tune: string;
  available: { width: number; height: number };
  onOpen: (entry: GalleryEntry, variant: string) => void;
  hrefFor: (entry: GalleryEntry, variant: string) => string;
}) {
  const [variant, setVariant] = useState(initialVariant);
  const variants = Object.keys(entry.variants);
  const fixture = entry.variants[variant];
  return (
    <article className="gallery-browse-card" data-gallery-browse-entry={entry.id}>
      <header className="gallery-browse-card-header">
        <div>
          <h2>{entry.title}</h2>
          <code>{entry.id}</code>
        </div>
        <span className="gallery-browse-kind">{fixture?.play ? "Motion" : "Static"}</span>
      </header>
      <div className="gallery-browse-variants" role="tablist" aria-label={`${entry.title} variants`}>
        {variants.map((name) => (
          <button
            key={name}
            type="button"
            role="tab"
            aria-selected={name === variant}
            className={name === variant ? "active" : undefined}
            onClick={() => setVariant(name)}
          >
            {name}
          </button>
        ))}
      </div>
      <Stage entry={entry} state={variant} env={env} tune={tune} available={available} thumbnail />
      <footer className="gallery-browse-card-footer">
        <a
          href={hrefFor(entry, variant)}
          onClick={(event) => {
            event.preventDefault();
            onOpen(entry, variant);
          }}
        >
          Open full view
        </a>
        <a href={browseFrameHref(entry, variant, env, tune)} target="_blank" rel="noreferrer">
          Open frame
        </a>
      </footer>
    </article>
  );
}
