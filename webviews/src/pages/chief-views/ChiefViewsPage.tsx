// The Chief view gallery beside the Chief: a switcher of dots (one per view that is on, like New
// Tab's), the gallery of every view (CHIEF_VIEWS) with its description, an on/off switch and where
// to open it, and the views themselves: one in the pane, and optionally a second beside it as a
// split (half) or a sidebar (a narrow column). Below NARROW of the page's own width the second
// view stacks under the first.
import { useEffect, useMemo, useSyncExternalStore } from "react";
import { useNow } from "../../ui/useNow";
import type { Strings } from "../shared/i18n";
import { ViewGlyph } from "./parts";
import { CHIEF_VIEWS, viewById, type ChiefViewManifest } from "./registry";
import type { ChiefViewsStore, ViewNeed } from "./store";
import type { Placement } from "./types";

const PLACEMENTS: Placement[] = ["pane", "split", "sidebar"];

export function ChiefViewsPage({
  store,
  strings,
  now: fixedNow,
}: {
  store: ChiefViewsStore;
  strings: Strings;
  /** A fixed clock (the gallery); else the page's own, a tick a minute for the "4 min" stamps. */
  now?: number;
}) {
  const data = useSyncExternalStore(store.subscribe, store.getSnapshot);
  const now = useMinuteNow(fixedNow);
  const { layout } = data;
  const main = viewById(layout.main);
  const side = layout.side ? viewById(layout.side.id) : undefined;
  const needs = useMemo(
    () => [...new Set([...(main?.needs ?? []), ...(side?.needs ?? [])])] as ViewNeed[],
    [main, side],
  );
  const needKey = needs.join(",");
  useEffect(() => {
    store.need(needKey ? (needKey.split(",") as ViewNeed[]) : []);
  }, [store, needKey]);
  const { t } = strings;
  const enabled = CHIEF_VIEWS.filter((view) => layout.enabled.includes(view.id));
  const props = {
    data,
    strings,
    now,
    onOpenAgent: store.open.bind(store),
    onOpenURL: store.openURL.bind(store),
    onSetFleetURL: store.setFleetURL.bind(store),
  };
  return (
    <div className="cv-page" data-catalog={data.catalog ? "" : undefined}>
      <header className="cv-header">
        {enabled.length > 0 && (
          <nav className="cv-dots" aria-label={t("chiefViews.page.title")}>
            {enabled.map((view) => (
              <button
                key={view.id}
                type="button"
                className="cv-dot"
                data-view={view.id}
                aria-current={view.id === layout.main ? "page" : undefined}
                aria-label={t(view.title)}
                title={t(view.title)}
                onClick={() => store.show(view.id, "pane")}
              >
                <ViewGlyph glyph={view.glyph} size={14} />
              </button>
            ))}
          </nav>
        )}
        <div className="cv-heading">
          <h1 className="cv-title">{main ? t(main.title) : t("chiefViews.page.title")}</h1>
          {main && <p className="cv-description">{t(main.description)}</p>}
        </div>
        <div className="cv-actions">
          {needs.some((need) => need !== "agents") && (
            <button type="button" className="cv-button" onClick={() => store.refresh(needs)}>
              {t("chiefViews.refresh")}
            </button>
          )}
          <button
            type="button"
            className="cv-button"
            aria-expanded={data.catalog}
            aria-controls="cv-gallery"
            onClick={() => store.setCatalog(!data.catalog)}
          >
            {t("chiefViews.gallery.button")}
          </button>
        </div>
      </header>
      {data.catalog && <Gallery store={store} strings={strings} enabled={layout.enabled} main={layout.main} />}
      {data.offline && <p className="cv-note cv-offline">{t("chiefViews.offline")}</p>}
      {main ? (
        <div className="cv-layout" data-side={layout.side?.placement}>
          <section className="cv-pane" data-view={main.id} aria-label={t(main.title)}>
            <main.component {...props} placement="pane" />
          </section>
          {side && layout.side && (
            <section
              className="cv-side"
              data-view={side.id}
              data-placement={layout.side.placement}
              aria-label={t(side.title)}
            >
              <div className="cv-side-head">
                <ViewGlyph glyph={side.glyph} size={12} />
                <h2 className="cv-side-title">{t(side.title)}</h2>
                <button type="button" className="cv-link" onClick={() => store.show(side.id, "pane")}>
                  {t("chiefViews.placement.pane")}
                </button>
                <button type="button" className="cv-link" onClick={() => store.closeSide()}>
                  {t("chiefViews.side.close")}
                </button>
              </div>
              <side.component {...props} placement={layout.side.placement} />
            </section>
          )}
        </div>
      ) : (
        !data.catalog && <p className="cv-note">{t("chiefViews.empty")}</p>
      )}
    </div>
  );
}

function Gallery({
  store,
  strings,
  enabled,
  main,
}: {
  store: ChiefViewsStore;
  strings: Strings;
  enabled: readonly string[];
  main?: string;
}) {
  const { t } = strings;
  return (
    <section id="cv-gallery" className="cv-gallery" aria-label={t("chiefViews.gallery.title")}>
      <div className="cv-gallery-head">
        <h2 className="cv-gallery-title">{t("chiefViews.gallery.title")}</h2>
        <p className="cv-description">{t("chiefViews.gallery.subtitle")}</p>
      </div>
      <ul className="cv-cards-grid">
        {CHIEF_VIEWS.map((view) => (
          <ViewCard
            key={view.id}
            view={view}
            strings={strings}
            on={enabled.includes(view.id)}
            canPlaceBeside={!!main && main !== view.id}
            onToggle={() => store.toggle(view.id)}
            onPlace={(placement) => {
              store.show(view.id, placement);
              store.setCatalog(false);
            }}
          />
        ))}
      </ul>
    </section>
  );
}

function ViewCard({
  view,
  strings,
  on,
  canPlaceBeside,
  onToggle,
  onPlace,
}: {
  view: ChiefViewManifest;
  strings: Strings;
  on: boolean;
  canPlaceBeside: boolean;
  onToggle: () => void;
  onPlace: (placement: Placement) => void;
}) {
  const { t } = strings;
  return (
    <li className="cv-card" data-view={view.id} data-on={on ? "" : undefined}>
      <div className="cv-card-head">
        <span className="cv-card-glyph">
          <ViewGlyph glyph={view.glyph} size={18} />
        </span>
        <h3 className="cv-card-title">{t(view.title)}</h3>
        <button
          type="button"
          role="switch"
          className="cv-switch"
          aria-checked={on}
          aria-label={t(view.title)}
          onClick={onToggle}
        >
          <span className="cv-switch-knob" />
        </button>
      </div>
      <p className="cv-card-description">{t(view.description)}</p>
      <div className="cv-card-place">
        <span className="cv-card-place-label">{t("chiefViews.placement.label")}</span>
        {PLACEMENTS.map((placement) => (
          <button
            key={placement}
            type="button"
            className="cv-segment"
            data-default={placement === view.defaultPlacement ? "" : undefined}
            disabled={placement !== "pane" && !canPlaceBeside}
            onClick={() => onPlace(placement)}
          >
            {t(`chiefViews.placement.${placement}`)}
          </button>
        ))}
      </div>
    </li>
  );
}

/** The fixed clock, else the page clock's current minute (ui/pageClock.ts): the same minute tick
 * the Lanes view keeps for its "Idle · 3 h" stamps, resting while the page is hidden. */
function useMinuteNow(fixed?: number): number {
  const minute = useNow("minute", { enabled: fixed === undefined });
  return fixed ?? minute;
}
