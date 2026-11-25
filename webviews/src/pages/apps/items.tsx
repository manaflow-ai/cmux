// The App Store's item primitives (design/app-store.md): one card, one hero, one list row, one
// action, one state badge, the category bar and the listing page's parts (screenshots, where the
// app shows up, permissions in plain words, its facts). Every listing draws through these, so a new
// app looks like the others and a new surface is a few lines. Apps only: cmux's own features stay
// in Settings (apps-web-DESIGN.md).
import { useState, type ReactNode, memo, type Ref } from "react";
import type { Strings } from "../shared/i18n";
import {
  categoryLabel,
  groupScopes,
  isRemovable,
  itemState,
  oneLine,
  placeLabel,
  RiskLabel,
  TierLabel,
  type CardStyle,
} from "./model";
import { AppIcon, Badge, Switch } from "./parts";
import { SourceLink } from "./SourceLink";
import type { AppsStore } from "./store";
import type { AppContribution, AppDetail, CatalogApp, ScopeRequest } from "./types";
import { UseAsNewTab } from "./UseAsNewTab";

type ItemProps = { app: CatalogApp; store: AppsStore; strings: Strings };

/** Both localized labels size the action, including the primary state's heavier type. */
function ActionLabel({ label, alternate }: { label: string; alternate: string }) {
  return (
    <span className="apps-action-label">
      <span>{label}</span>
      <span className="apps-action-label-size" aria-hidden="true">
        {label}
      </span>
      <span className="apps-action-label-size" aria-hidden="true">
        {alternate}
      </span>
    </span>
  );
}

/**
 * The one action a listing offers: Install when absent, Remove when removable, else Hide/Show (a
 * first-party app ships with cmux and is hidden or shown, never removed; FIRST-PARTY-APPS).
 */
export function ItemAction({ app, store, strings }: ItemProps) {
  const { t } = strings;
  if (app.installed && !isRemovable(app)) {
    return (
      <button
        type="button"
        className="apps-button"
        data-listing-action={app.hidden ? "show" : "hide"}
        onClick={(event) => {
          event.stopPropagation();
          void store.setHidden(app.id, !app.hidden);
        }}
      >
        <ActionLabel
          label={t(app.hidden ? "store.action.show" : "store.action.hide")}
          alternate={t(app.hidden ? "store.action.hide" : "store.action.show")}
        />
      </button>
    );
  }
  return (
    <button
      type="button"
      className={`apps-button${app.installed ? "" : " primary"}`}
      data-listing-action={app.installed ? "remove" : "install"}
      onClick={(event) => {
        event.stopPropagation();
        void (app.installed ? store.uninstall(app.id) : store.install(app.id));
      }}
    >
      <ActionLabel
        label={t(app.installed ? "store.action.remove" : "store.action.install")}
        alternate={t(app.installed ? "store.action.install" : "store.action.remove")}
      />
    </button>
  );
}

/** Installed or Disabled; nothing for an app that is not installed. */
export function StateBadge({ app, strings }: { app: CatalogApp; strings: Strings }) {
  const state = itemState(app);
  if (state === "available") return null;
  return <Badge text={strings.t(state === "off" ? "store.badge.disabled" : "store.badge.installed")} />;
}

function Publisher({ app, strings }: { app: CatalogApp; strings: Strings }) {
  return (
    <span className="apps-card-meta">
      <span>{app.publisher}</span>
      {app.publisher_verified && (
        <span className="apps-verified" title={strings.t("store.tier.verified")} aria-hidden="true">
          ✓
        </span>
      )}
    </span>
  );
}

function descriptionId(app: CatalogApp, scope = "description"): string {
  return `apps-${scope}-${app.id.replace(/[^a-z0-9_-]/gi, "-")}`;
}

/**
 * A listing as a card: icon, name, publisher, its one line (the tagline, else the description),
 * then its category, state and the action. `standard` is the catalog card; `compact` is one line
 * and the action only; `artwork` leads with the icon on a tinted panel. The non-default styles are
 * DEV variants (`card=` in the route, the gallery). Memoized: the windowed catalog draws a card
 * again only when its own listing changes. `position` and `count` place it among every listing
 * for a screen reader when only the cards near the viewport are mounted.
 */
export const ItemCard = memo(function ItemCard({
  app,
  store,
  strings,
  style,
  featured = false,
  position,
  count,
  ref,
}: ItemProps & {
  style: CardStyle;
  featured?: boolean;
  position?: number;
  count?: number;
  /** The windowed catalog measures its rows by their cards (AppsPage.tsx CatalogList). */
  ref?: Ref<HTMLElement>;
}) {
  const { t } = strings;
  const id = descriptionId(app);
  const classes = `apps-card${featured ? " featured" : ""}${style === "standard" ? "" : ` ${style}`}`;
  const iconSize = style === "compact" ? 32 : style === "artwork" ? 56 : featured ? 56 : 48;
  const open = (
    <button
      type="button"
      className="apps-card-open"
      onClick={() => void store.select(app.id)}
      aria-label={app.name}
      aria-describedby={id}
    >
      {style === "artwork" ? (
        <span className="apps-card-art">
          <AppIcon icon={app.icon} name={app.name} size={iconSize} />
        </span>
      ) : (
        <AppIcon icon={app.icon} name={app.name} size={iconSize} />
      )}
      <span className="apps-card-text">
        <span className="apps-name">{app.name}</span>
        {style !== "compact" && <Publisher app={app} strings={strings} />}
        <span className={`apps-description${style === "compact" ? " one-line" : ""}`} id={id}>
          {oneLine(app)}
        </span>
      </span>
    </button>
  );
  return (
    <article
      ref={ref}
      className={classes}
      data-card-style={style}
      data-item-state={itemState(app)}
      data-app={app.id}
      aria-posinset={position}
      aria-setsize={count}
    >
      {style === "compact" ? (
        <div className="apps-card-line">
          {open}
          <StateBadge app={app} strings={strings} />
          <ItemAction app={app} store={store} strings={strings} />
        </div>
      ) : (
        open
      )}
      {style !== "compact" && (
        <footer className="apps-card-footer">
          {app.categories[0] && <Badge text={categoryLabel(app.categories[0], t)} />}
          <StateBadge app={app} strings={strings} />
          <span className="apps-card-actions">
            {app.installed && <UseAsNewTab app={app} strings={strings} />}
            <ItemAction app={app} store={store} strings={strings} />
          </span>
        </footer>
      )}
    </article>
  );
});

/**
 * Discover's hero (the App Store's Today card): the featured app large, with its tagline, the
 * action, and a screenshot of it in use (`preview`), else its icon on a tinted panel.
 */
export const HeroCard = memo(function HeroCard({ app, preview, store, strings }: ItemProps & { preview?: string }) {
  const id = descriptionId(app, "hero");
  const select = () => void store.select(app.id);
  return (
    <article className="apps-hero" data-item-state={itemState(app)}>
      <div className="apps-hero-text">
        <span className="apps-hero-eyebrow">{strings.t("store.browse.featured")}</span>
        <button type="button" className="apps-hero-open" onClick={select} aria-label={app.name} aria-describedby={id}>
          <AppIcon icon={app.icon} name={app.name} size={64} />
          <span className="apps-hero-title">
            <span className="apps-hero-name">{app.name}</span>
            <Publisher app={app} strings={strings} />
          </span>
        </button>
        <p className="apps-hero-tagline" id={id}>
          {oneLine(app)}
        </p>
        <span className="apps-hero-actions">
          <ItemAction app={app} store={store} strings={strings} />
          <StateBadge app={app} strings={strings} />
        </span>
      </div>
      {/* The picture opens the page too; the name above is its accessible way in. */}
      <button type="button" className="apps-hero-art" onClick={select} tabIndex={-1} aria-hidden="true">
        {preview?.startsWith("data:image/") ? (
          <img src={preview} alt="" className="apps-hero-shot" />
        ) : (
          <AppIcon icon={app.icon} name={app.name} size={112} />
        )}
      </button>
    </article>
  );
});

/** A listing as a store list row (the Raycast Store): icon, name and one line, categories, action;
 *  memoized like the card. */
export const ListRow = memo(function ListRow({ app, store, strings }: ItemProps) {
  const id = descriptionId(app, "line");
  return (
    <div className="apps-list-row" data-item-state={itemState(app)}>
      <button
        type="button"
        className="apps-list-open"
        onClick={() => void store.select(app.id)}
        aria-label={app.name}
        aria-describedby={id}
      >
        <AppIcon icon={app.icon} name={app.name} size={40} />
        <span className="apps-list-text">
          <span className="apps-name">{app.name}</span>
          <span className="apps-description one-line" id={id}>
            {oneLine(app)}
          </span>
        </span>
      </button>
      <span className="apps-list-chips">
        {app.categories.slice(0, 2).map((category) => (
          <span key={category} className="apps-tag">
            {categoryLabel(category, strings.t)}
          </span>
        ))}
      </span>
      <Publisher app={app} strings={strings} />
      <span className="apps-list-action">
        <ItemAction app={app} store={store} strings={strings} />
      </span>
    </div>
  );
});

/** A listing as a list row (the list and split layouts); memoized like the card. */
export const ItemRow = memo(function ItemRow({ app, selected, store, strings }: ItemProps & { selected: boolean }) {
  return (
    <div className={`apps-row${selected ? " selected" : ""}`} data-item-state={itemState(app)}>
      <button type="button" className="apps-row-open" onClick={() => void store.select(app.id)} aria-label={app.name}>
        <AppIcon icon={app.icon} name={app.name} size={28} />
        <span className="apps-row-text">
          <span className="apps-name">{app.name}</span>
          <Publisher app={app} strings={strings} />
          <span className="apps-description">{oneLine(app)}</span>
        </span>
      </button>
      <Badge text={strings.t(TierLabel[app.tier])} />
      <ItemAction app={app} store={store} strings={strings} />
    </div>
  );
});

/**
 * All, then each category present on the shelf; the selected one is pressed. With `examples` (the
 * owner offers the SDK examples), an Examples toggle ends the row, set apart from the categories.
 */
export function CategoryBar({
  categories,
  selected,
  onSelect,
  examples,
  strings,
}: {
  categories: readonly string[];
  selected?: string;
  onSelect: (category: string | undefined) => void;
  examples?: { selected: boolean; onToggle: () => void };
  strings: Strings;
}) {
  const { t } = strings;
  const chip = (category: string | undefined, label: string) => (
    <button
      key={category ?? ""}
      type="button"
      className={`apps-chip${selected === category ? " selected" : ""}`}
      aria-pressed={selected === category}
      onClick={() => onSelect(category)}
    >
      {label}
    </button>
  );
  return (
    <div className="apps-chips" data-store-section="categories">
      {chip(undefined, t("store.category.all"))}
      {categories.map((category) => chip(category, categoryLabel(category, t)))}
      {examples && (
        <button
          type="button"
          className={`apps-chip apps-chip-shelf${examples.selected ? " selected" : ""}`}
          aria-pressed={examples.selected}
          onClick={examples.onToggle}
        >
          {t("store.shelf.examples")}
        </button>
      )}
    </div>
  );
}

/**
 * One titled section of a listing's page; every section shares this head and spacing. `section`
 * names it for capture drivers and tests (`data-listing-section`).
 */
export function DetailSection({ title, section, children }: { title: string; section?: string; children: ReactNode }) {
  return (
    <section className="apps-section" data-listing-section={section}>
      <h2>{title}</h2>
      {children}
    </section>
  );
}

/** The screenshots the store loaded, as data URLs only (the page loads nothing from the network). */
function images(screenshots: readonly string[]): string[] {
  return screenshots.filter((src) => src.startsWith("data:image/"));
}

/**
 * The screenshots strip (the iOS App Store's row): every screenshot at one height, scrolling
 * sideways. Shows when the owner lists any screenshot, and draws only the loaded ones.
 */
export function ScreenshotStrip({ screenshots, strings }: { screenshots: readonly string[]; strings: Strings }) {
  if (screenshots.length === 0) return null;
  return (
    <DetailSection title={strings.t("store.detail.screenshots")} section="screenshots">
      <div className="apps-screenshots">
        {images(screenshots).map((src, index) => (
          <img key={index} src={src} alt="" className="apps-screenshot" />
        ))}
      </div>
    </DetailSection>
  );
}

/**
 * The screenshot carousel (the Mac App Store's): the selected screenshot large, the others as
 * thumbnails under it; an animated image plays as the app's loop. Nothing until one has loaded.
 */
export function ScreenshotCarousel({ screenshots, strings }: { screenshots: readonly string[]; strings: Strings }) {
  const [selected, setSelected] = useState(0);
  const shown = images(screenshots);
  if (shown.length === 0) return null;
  const index = Math.min(selected, shown.length - 1);
  const label = (at: number) => strings.format("store.detail.screenshot", String(at + 1));
  return (
    <div className="apps-carousel" data-listing-section="screenshots">
      <img src={shown[index]} alt={label(index)} className="apps-carousel-main" />
      {shown.length > 1 && (
        <div className="apps-carousel-thumbs">
          {shown.map((src, at) => (
            <button
              key={at}
              type="button"
              className={`apps-carousel-thumb${at === index ? " selected" : ""}`}
              aria-pressed={at === index}
              aria-label={label(at)}
              data-screenshot-thumb={at + 1}
              onClick={() => setSelected(at)}
            >
              <img src={src} alt="" />
            </button>
          ))}
        </div>
      )}
    </div>
  );
}

/**
 * "Shows up in": each place the app puts something (Sidebar, Title bar, its own tab, New Tab,
 * Command palette) with what it puts there. A kind the page does not know shows only its title.
 */
export function ShowsUpIn({ contributes, strings }: { contributes?: readonly AppContribution[]; strings: Strings }) {
  if (!contributes?.length) return null;
  // One row per place, in the owner's order, with every title the app puts there.
  const places: { place: string; titles: string[] }[] = [];
  for (const item of contributes) {
    const place = placeLabel(item.kind, strings.t) ?? "";
    const row = places.find((known) => known.place === place);
    if (row) row.titles.push(item.title);
    else places.push({ place, titles: [item.title] });
  }
  return (
    <DetailSection title={strings.t("store.detail.showsUpIn")} section="shows-up-in">
      <dl className="apps-facts">
        {places.map(({ place, titles }, index) => (
          <div key={`${index}\u0000${place}`} className="apps-fact">
            <dt>{place}</dt>
            <dd>
              {titles.map((title, at) => (
                <span key={at} className="apps-fact-line">
                  {title}
                </span>
              ))}
            </dd>
          </div>
        ))}
      </dl>
    </DetailSection>
  );
}

/**
 * Permissions in plain words: a heading per kind of access (Cloud machines, Files, Terminals...)
 * from the scope's namespace, and the app's reason for each; optional ones say so. The scope id
 * itself is never on screen.
 */
export function PermissionList({ scopes, strings }: { scopes: readonly ScopeRequest[]; strings: Strings }) {
  const { t } = strings;
  return (
    <DetailSection title={t("store.detail.permissions")} section="permissions">
      {scopes.length === 0 ? (
        <p className="apps-muted">{t("store.detail.noPermissions")}</p>
      ) : (
        <div className="apps-perms">
          {groupScopes(scopes, t).map((group, index) => (
            <div key={`${index}\u0000${group.heading ?? ""}`} className="apps-perm-group">
              {group.heading && <span className="apps-perm-heading">{group.heading}</span>}
              <ul className="apps-perm-rows">
                {group.rows.map((row) => (
                  <li key={row.scope} className="apps-perm">
                    <span className="selectable">{row.reason}</span>
                    {row.optional && <Badge text={t("store.detail.optional")} />}
                    {row.risk !== "standard" && <Badge text={t(RiskLabel[row.risk])} />}
                  </li>
                ))}
              </ul>
            </div>
          ))}
        </div>
      )}
    </DetailSection>
  );
}

/** The cmux versions a version works with, as a person reads them (`^1.0` is 1.0). */
function engineText(engines: string): string {
  return engines.replace(/^[\^~>=v\s]+/, "");
}

/** The listing's facts (the Mac App Store's Information): developer, category, version, repository. */
export function InfoFacts({ detail, strings }: { detail: AppDetail; strings: Strings }) {
  const { t, format } = strings;
  const latest = detail.versions.find((version) => version.version === detail.latest_version) ?? detail.versions[0];
  const rows: [string, ReactNode][] = [
    [
      t("store.detail.developer"),
      <span key="developer" className="apps-listing-publisher">
        {detail.publisher}
        {detail.publisher_verified && (
          <span className="apps-verified" title={t("store.tier.verified")} aria-hidden="true">
            ✓
          </span>
        )}
      </span>,
    ],
    ...(detail.categories.length
      ? [
          [t("store.detail.category"), detail.categories.map((category) => categoryLabel(category, t)).join(", ")] as [
            string,
            ReactNode,
          ],
        ]
      : []),
    [
      t("store.detail.version"),
      <>
        <span className="apps-fact-line">{detail.latest_version}</span>
        {latest?.engines && (
          <span className="apps-fact-line apps-muted">
            {format("store.detail.requires", engineText(latest.engines))}
          </span>
        )}
      </>,
    ],
  ];
  return (
    <DetailSection title={t("store.detail.information")} section="info">
      <dl className="apps-facts">
        {rows.map(([label, value]) => (
          <div key={label} className="apps-fact">
            <dt>{label}</dt>
            <dd>{value}</dd>
          </div>
        ))}
      </dl>
      <SourceLink source={detail} strings={strings} />
    </DetailSection>
  );
}

/** An installed app's settings on its page: Enabled, the same switch as the Installed tab. */
export function ItemSettings({ app, store, strings }: ItemProps) {
  if (!app.installed) return null;
  const { t } = strings;
  return (
    <DetailSection title={t("store.detail.settings")}>
      <div className="apps-setting">
        <span>{t("store.action.enabled")}</span>
        <Switch
          on={app.enabled !== false}
          label={t("store.action.enabled")}
          onChange={(on) => void store.setEnabled(app.id, on)}
        />
      </div>
    </DetailSection>
  );
}
