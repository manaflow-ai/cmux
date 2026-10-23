// The App Store's item primitives (design/app-store.md): one card, one row, one action, one state
// badge, the category bar and the detail page's sections. Every listing draws through these, so
// a new app looks like the others and a new surface is a few lines. Apps only: cmux's own
// features stay in Settings (apps-web-DESIGN.md).
import type { ReactNode } from "react";
import type { Strings } from "../shared/i18n";
import { categoryLabel, isRemovable, itemState, TierLabel, type CardStyle } from "./model";
import { AppIcon, Badge, Switch } from "./parts";
import type { AppsStore } from "./store";
import type { AppContribution, CatalogApp } from "./types";

type ItemProps = { app: CatalogApp; store: AppsStore; strings: Strings };

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
        onClick={(event) => {
          event.stopPropagation();
          void store.setHidden(app.id, !app.hidden);
        }}
      >
        {t(app.hidden ? "store.action.show" : "store.action.hide")}
      </button>
    );
  }
  return (
    <button
      type="button"
      className={`apps-button${app.installed ? "" : " primary"}`}
      onClick={(event) => {
        event.stopPropagation();
        void (app.installed ? store.uninstall(app.id) : store.install(app.id));
      }}
    >
      {t(app.installed ? "store.action.remove" : "store.action.install")}
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

function descriptionId(app: CatalogApp): string {
  return `apps-description-${app.id.replace(/[^a-z0-9_-]/gi, "-")}`;
}

/**
 * A listing as a card. `standard` (the default) is the catalog card: icon, name, publisher, a
 * two-line description, tier/category/state badges, Preview and the action. `compact` is one line
 * of description and the action only; `artwork` leads with the icon on a tinted panel. The
 * non-default styles are DEV variants (`card=` in the route, the gallery).
 */
export function ItemCard({
  app,
  store,
  strings,
  style,
  featured = false,
}: ItemProps & { style: CardStyle; featured?: boolean }) {
  const { t } = strings;
  const id = descriptionId(app);
  const classes = `apps-card${featured ? " featured" : ""}${style === "standard" ? "" : ` ${style}`}`;
  const iconSize = style === "compact" ? 32 : style === "artwork" ? 56 : featured ? 52 : 44;
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
          {app.description}
        </span>
      </span>
    </button>
  );
  return (
    <article className={classes} data-card-style={style} data-item-state={itemState(app)}>
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
          <Badge text={t(TierLabel[app.tier])} />
          {app.categories[0] && <Badge text={categoryLabel(app.categories[0], t)} />}
          <StateBadge app={app} strings={strings} />
          <span className="apps-card-actions">
            <button type="button" className="apps-button apps-button-subtle" onClick={() => void store.select(app.id)}>
              {t("store.detail.preview")}
            </button>
            <ItemAction app={app} store={store} strings={strings} />
          </span>
        </footer>
      )}
    </article>
  );
}

/** A listing as a list row (the list and split layouts). */
export function ItemRow({ app, selected, store, strings }: ItemProps & { selected: boolean }) {
  return (
    <div className={`apps-row${selected ? " selected" : ""}`} data-item-state={itemState(app)}>
      <button type="button" className="apps-row-open" onClick={() => void store.select(app.id)} aria-label={app.name}>
        <AppIcon icon={app.icon} name={app.name} size={28} />
        <span className="apps-row-text">
          <span className="apps-name">{app.name}</span>
          <Publisher app={app} strings={strings} />
          <span className="apps-description">{app.description}</span>
        </span>
      </button>
      <Badge text={strings.t(TierLabel[app.tier])} />
      <ItemAction app={app} store={store} strings={strings} />
    </div>
  );
}

/** All, then each category present in the catalog; the selected one is pressed. */
export function CategoryBar({
  categories,
  selected,
  onSelect,
  strings,
}: {
  categories: readonly string[];
  selected?: string;
  onSelect: (category: string | undefined) => void;
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
    <div className="apps-chips">
      {chip(undefined, t("store.category.all"))}
      {categories.map((category) => chip(category, categoryLabel(category, t)))}
    </div>
  );
}

/** One titled section of a listing's page; every section shares this head and spacing. */
export function DetailSection({ title, children }: { title: string; children: ReactNode }) {
  return (
    <section className="apps-section">
      <h2>{title}</h2>
      {children}
    </section>
  );
}

/**
 * The screenshots strip: the section shows when the owner lists any screenshot, and draws only the
 * ones sent as data URLs (the page loads nothing from the network).
 */
export function ScreenshotStrip({ screenshots, strings }: { screenshots: readonly string[]; strings: Strings }) {
  if (screenshots.length === 0) return null;
  return (
    <DetailSection title={strings.t("store.detail.screenshots")}>
      <div className="apps-screenshots">
        {screenshots
          .filter((src) => src.startsWith("data:image/"))
          .map((src, index) => (
            <img key={index} src={src} alt="" className="apps-screenshot" />
          ))}
      </div>
    </DetailSection>
  );
}

// A Map, not an object literal: a kind such as "__proto__" or "constructor" must not resolve.
const CONTRIBUTION_KEYS = new Map<string, string>([
  ["section", "store.contribution.section"],
  ["command", "store.contribution.command"],
  ["statusItem", "store.contribution.statusItem"],
]);

function kindLabel(kind: string, strings: Strings): string {
  const key = CONTRIBUTION_KEYS.get(kind);
  return key ? strings.t(key) : kind;
}

/** "What it adds": the places the app puts something in cmux, each with its kind. */
export function AddsList({ contributes, strings }: { contributes?: readonly AppContribution[]; strings: Strings }) {
  if (!contributes?.length) return null;
  const { t } = strings;
  return (
    <DetailSection title={t("store.detail.adds")}>
      <ul className="apps-adds">
        {contributes.map((item, index) => (
          <li key={`${index}\u0000${item.kind}\u0000${item.title}`} className="apps-add">
            <span className="apps-add-title">{item.title}</span>
            <Badge text={kindLabel(item.kind, strings)} />
          </li>
        ))}
      </ul>
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
