// Settings > Appearance > Looks (lead card `looksGallery`). Leo, 2026-11-19: "all of them" and
// "some of them maybe just as customizations lol if it affects default looks". A look is a setup repo
// (docs/cmux-next/setup-repos.md) from the reviewed catalog: each tile shows it on the golden sample
// for the page's light or dark, and Install puts it on the person's stack after its consent card;
// installed looks turn on and off, stack top first and uninstall. Installing is the person's opt-in:
// the gallery itself changes nothing about the default look. The CLI owns the catalog, the previews,
// the stack and every write (`cmux setup gallery|preview|install|remove|on|off|order`), run through
// the host's bundled CLI (`cmux.settings.looks`), so the card and the CLI never differ. The list is
// read with the section (sectionQueries) and again after each change; it does not poll. Opened at
// this card by `#/settings/appearance?focus=card.looksGallery`.
import { useQuery, useQueryClient } from "@tanstack/react-query";
import { useEffect, useId, useLayoutEffect, useRef, useState } from "react";
import { Button } from "../../../ui/Button";
import { focusRoute } from "../../../ui/focusRoute";
import { useColorScheme } from "../colorScheme";
import { useSettingsSelector, useStore } from "../context";
import { Switch } from "../editors/ToggleEditor";
import { Icon } from "../icons";
import { lookDescriptionsOf, traitLine, type LookDescriptions } from "../lookDescriptions";
import { consentLines, moveOrder, pinnedReference, shortCommit } from "../looksGallery";
import type { Look, LookConsentCard, LookLayer, LooksGallery, LooksRun } from "../ops";
import { LOOKS_KEY, lookPreviewQuery, looksQuery, storePreviewLoader, type LookPreviewLoader } from "../sectionQueries";
import { t } from "../strings";

/** How the catalog draws (gallery `settings.looks-gallery-layouts`). `grid`, the shipped one, is a
 * grid of equal tiles, each its golden sample over its name; `hero` draws the first look large over a
 * rail of the rest; `list` is one compact row per look with a small preview. */
export type LooksLayout = "grid" | "hero" | "list";

/** The page's gestures on the gallery. */
export type LooksActions = {
  /** Install: asks the CLI for the look's consent card (nothing changes yet). */
  onInstall: (look: Look) => void;
  onToggle: (id: string, on: boolean) => void;
  onMove: (id: string, by: -1 | 1) => void;
  /** Uninstall: asks first. */
  onRemove: (layer: LookLayer) => void;
};

export function LooksGalleryCard({ reveal = false }: { reveal?: boolean }) {
  const store = useStore();
  const queryClient = useQueryClient();
  const query = useQuery(looksQuery(store));
  const scheme = useColorScheme();
  const descriptions = useSettingsSelector(lookDescriptionsOf);
  const [loadPreview] = useState(() => storePreviewLoader(store));
  const [busy, setBusy] = useState<string | null>(null);
  const [refusal, setRefusal] = useState<string | null>(null);
  const [consent, setConsent] = useState<LookConsentCard | null>(null);
  const [removing, setRemoving] = useState<LookLayer | null>(null);
  const read = query.data ?? null;
  // The store never rejects (a failed call answers a refusal), so the busy state always ends. A
  // gallery read still on its way saw the stack before this change: it is dropped before the change
  // runs, and the gallery is read again after it. Only the gallery's own key: the tiles' previews
  // stay cached. An install without `yes` changes nothing and answers the consent card to show.
  const run = (change: LooksRun, busyId: string) => {
    setBusy(busyId);
    setRefusal(null);
    return queryClient
      .cancelQueries({ queryKey: LOOKS_KEY, exact: true })
      .then(() => store.looks(change))
      .then(async (outcome) => {
        if (outcome?.kind === "consent") {
          setConsent(outcome.card);
          return;
        }
        setConsent(null);
        setRemoving(null);
        if (outcome?.kind === "refusal") setRefusal(outcome.message);
        await queryClient.refetchQueries({ queryKey: LOOKS_KEY, exact: true });
      })
      .finally(() => setBusy(null));
  };
  // A host with no Looks part or no CLI shows no card; a CLI that refuses the read does, saying why.
  if (!query.isFetched || read === null) return null;
  const gallery = read.gallery;
  const actions: LooksActions = {
    onInstall: (look) => {
      setRemoving(null);
      void run({ verb: "install", reference: look.repo }, look.id);
    },
    onToggle: (id, on) => void run({ verb: on ? "on" : "off", id }, id),
    onMove: (id, by) => {
      const ids = moveOrder(gallery?.stack.map((layer) => layer.id) ?? [], id, by);
      if (ids) void run({ verb: "order", ids }, id);
    },
    onRemove: (layer) => {
      setConsent(null);
      setRemoving(layer);
    },
  };
  return (
    <LooksGalleryView
      gallery={gallery}
      readRefusal={read.refusal}
      refusal={refusal}
      busy={busy}
      consent={consent}
      removing={removing}
      reveal={reveal}
      descriptions={descriptions}
      scheme={scheme}
      loadPreview={loadPreview}
      actions={actions}
      onConfirmInstall={(card) =>
        void run({ verb: "install", reference: pinnedReference(card), yes: true }, card.setup.id)
      }
      onCancelInstall={() => setConsent(null)}
      onConfirmRemove={(layer) => void run({ verb: "remove", id: layer.id }, layer.id)}
      onCancelRemove={() => setRemoving(null)}
    />
  );
}

/** The card as it draws, from the gallery: the gallery draws it with fixtures. */
export function LooksGalleryView({
  gallery,
  drawn = true,
  readRefusal = null,
  refusal = null,
  busy = null,
  consent = null,
  removing = null,
  reveal = false,
  layout = "grid",
  descriptions = "phrase",
  scheme,
  loadPreview,
  actions,
  onConfirmInstall,
  onCancelInstall,
  onConfirmRemove,
  onCancelRemove,
}: {
  gallery: LooksGallery | null;
  drawn?: boolean;
  readRefusal?: string | null;
  refusal?: string | null;
  /** The id a change is running for (its button says so); every control waits meanwhile. */
  busy?: string | null;
  /** The consent card of the look whose Install was pressed. */
  consent?: LookConsentCard | null;
  removing?: LookLayer | null;
  /** The route opens the page on this card: it scrolls to the card once drawn. */
  reveal?: boolean;
  layout?: LooksLayout;
  /** How each tile describes its look (`experiments.lookDescriptions`). */
  descriptions?: LookDescriptions;
  scheme: "light" | "dark";
  loadPreview: LookPreviewLoader;
  actions: LooksActions;
  onConfirmInstall: (card: LookConsentCard) => void;
  onCancelInstall: () => void;
  onConfirmRemove: (layer: LookLayer) => void;
  onCancelRemove: () => void;
}) {
  const card = useRef<HTMLElement>(null);
  useLayoutEffect(() => {
    if (reveal) card.current?.scrollIntoView?.({ block: "start" });
  }, [reveal]);
  const looks = gallery?.looks ?? [];
  const stack = gallery?.stack ?? [];
  return (
    <section className="group" data-card="looksGallery" data-looks-layout={layout} id="looks-gallery" ref={card}>
      <h3 className="group-title">{t("settingsPage.looksGallery.title")}</h3>
      <div className="rows">
        {drawn && gallery === null ? (
          <div className="row" data-looks-unavailable="">
            <span className="row-help">{readRefusal ?? t("settingsPage.looksGallery.unavailable")}</span>
          </div>
        ) : drawn && looks.length === 0 ? (
          <div className="row" data-looks-empty="">
            <span className="row-help">{t("settingsPage.looksGallery.empty")}</span>
          </div>
        ) : gallery ? (
          <>
            <div className="row" data-looks-help="">
              <span className="row-help">{t("settingsPage.looksGallery.help")}</span>
            </div>
            <LooksCatalog
              looks={looks}
              layout={layout}
              descriptions={descriptions}
              busy={busy}
              scheme={scheme}
              loadPreview={loadPreview}
              actions={actions}
            />
          </>
        ) : null}
      </div>
      {consent && <ConsentSheet card={consent} busy={busy} onConfirm={onConfirmInstall} onCancel={onCancelInstall} />}
      {removing && <RemoveSheet layer={removing} busy={busy} onConfirm={onConfirmRemove} onCancel={onCancelRemove} />}
      {refusal && (
        <div className="row-error" role="alert" data-looks-refusal="">
          {t("settingsPage.looksGallery.refused", refusal)}
        </div>
      )}
      {stack.length > 0 && <StackedLooks stack={stack} busy={busy} actions={actions} />}
    </section>
  );
}

/** Every catalog look in `layout`. */
export function LooksCatalog({
  looks,
  layout,
  descriptions = "phrase",
  busy,
  scheme,
  loadPreview,
  actions,
}: {
  looks: readonly Look[];
  layout: LooksLayout;
  descriptions?: LookDescriptions;
  busy: string | null;
  scheme: "light" | "dark";
  loadPreview: LookPreviewLoader;
  actions: LooksActions;
}) {
  const tile = (look: Look, size: "large" | "tile" | "row") => (
    <LookTile
      key={look.id}
      look={look}
      size={size}
      descriptions={descriptions}
      busy={busy}
      scheme={scheme}
      loadPreview={loadPreview}
      actions={actions}
    />
  );
  if (layout === "list") return <div className="looks-list">{looks.map((look) => tile(look, "row"))}</div>;
  if (layout === "hero") {
    const [first, ...rest] = looks;
    return (
      <div className="looks-hero">
        {first && tile(first, "large")}
        {rest.length > 0 && <div className="looks-rail">{rest.map((look) => tile(look, "tile"))}</div>}
      </div>
    );
  }
  return <div className="looks-grid">{looks.map((look) => tile(look, "tile"))}</div>;
}

/** One look: its golden sample, name, tagline (as `descriptions` says), and Install, or its switch
 * and Uninstall. */
export function LookTile({
  look,
  size,
  descriptions = "phrase",
  busy,
  scheme,
  loadPreview,
  actions,
}: {
  look: Look;
  size: "large" | "tile" | "row";
  descriptions?: LookDescriptions;
  busy: string | null;
  scheme: "light" | "dark";
  loadPreview: LookPreviewLoader;
  actions: LooksActions;
}) {
  const labelId = useId();
  const installed = look.installed;
  const traits = descriptions === "tagged" ? traitLine(look.traits) : null;
  const controls = installed ? (
    <span className="looks-controls">
      <span className="looks-switch">
        <span className="row-help">{t("settingsPage.looksGallery.on")}</span>
        <Switch
          checked={installed.on}
          disabled={busy !== null}
          labelId={labelId}
          onToggle={(next) => actions.onToggle(look.id, next)}
        />
      </span>
      <Button
        variant="ghost"
        size="sm"
        className="button"
        data-looks-action="uninstall"
        aria-label={`${t("settingsPage.looksGallery.uninstall")}: ${look.name}`}
        disabled={busy !== null}
        onClick={() => actions.onRemove(installed)}
      >
        {t("settingsPage.looksGallery.uninstall")}
      </Button>
    </span>
  ) : (
    <span className="looks-controls">
      <Button
        size="sm"
        className="button"
        data-looks-action="install"
        aria-label={`${t("settingsPage.looksGallery.install")}: ${look.name}`}
        disabled={busy !== null}
        onClick={() => actions.onInstall(look)}
      >
        {busy === look.id ? t("settingsPage.looksGallery.installing") : t("settingsPage.looksGallery.install")}
      </Button>
    </span>
  );
  return (
    <div
      className="looks-tile"
      data-size={size}
      data-descriptions={descriptions}
      data-look={look.id}
      data-installed={installed ? "" : undefined}
      data-on={installed?.on ? "" : undefined}
    >
      <LookPreviewImage look={look} scheme={scheme} loadPreview={loadPreview} />
      <div className="looks-tile-body">
        <div className="looks-tile-text">
          <span className="row-title" id={labelId}>
            {look.name}
          </span>
          {descriptions !== "name" && <span className="row-help looks-tagline">{look.tagline}</span>}
          {traits && <span className="row-help looks-traits">{traits}</span>}
        </div>
        {controls}
      </div>
    </div>
  );
}

/** A look's golden sample for `scheme`. It asks for the image only once the tile is near the
 * screen, and holds a fixed-aspect placeholder until then, so the grid never moves as tiles fill. */
function LookPreviewImage({
  look,
  scheme,
  loadPreview,
}: {
  look: Look;
  scheme: "light" | "dark";
  loadPreview: LookPreviewLoader;
}) {
  const frame = useRef<HTMLDivElement>(null);
  const [near, setNear] = useState(false);
  useEffect(() => {
    const element = frame.current;
    if (!element || near) return;
    if (typeof IntersectionObserver === "undefined") {
      setNear(true);
      return;
    }
    const observer = new IntersectionObserver(
      (entries) => {
        if (!entries.some((entry) => entry.isIntersecting)) return;
        observer.disconnect();
        setNear(true);
      },
      { rootMargin: "200px 0px" },
    );
    observer.observe(element);
    return () => observer.disconnect();
  }, [near]);
  const preview = useQuery({ ...lookPreviewQuery(loadPreview, look.id, scheme), enabled: near });
  const image = preview.data?.dataUrl ?? null;
  const missing = preview.isFetched && !image;
  return (
    <div
      className="looks-preview"
      ref={frame}
      data-looks-preview={image ? "shown" : missing ? "missing" : "waiting"}
      aria-hidden={image ? undefined : true}
    >
      {image ? (
        <img src={image} alt={t("settingsPage.looksGallery.previewAlt", look.name)} draggable={false} />
      ) : missing ? (
        <span className="looks-preview-missing row-help">
          <Icon name="paintpalette" />
          {t("settingsPage.looksGallery.previewMissing")}
        </span>
      ) : null}
    </div>
  );
}

/** The consent card the CLI answered for Install, in the page's words: where it comes from and at
 * which commit, that cmux did not review it, and everything it changes. Install pins that commit. */
function ConsentSheet({
  card,
  busy,
  onConfirm,
  onCancel,
}: {
  card: LookConsentCard;
  busy: string | null;
  onConfirm: (card: LookConsentCard) => void;
  onCancel: () => void;
}) {
  const sheet = useRef<HTMLDivElement>(null);
  const title = t("settingsPage.looksGallery.consentTitle", card.setup.name);
  // It draws under the gallery, maybe screens below the tile whose Install opened it: it scrolls into
  // view and takes focus on Cancel, the safe answer.
  useLayoutEffect(() => {
    sheet.current?.scrollIntoView?.({ block: "nearest" });
    focusRoute(
      sheet.current?.querySelector<HTMLButtonElement>('[data-looks-action="cancel"]'),
      "person",
      "the person's Install opened the look's consent card: Cancel",
    );
  }, [card]);
  const lines = consentLines(card);
  return (
    <div
      className="accounts-form looks-sheet"
      data-looks-consent={card.setup.id}
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
      role="group"
      aria-label={title}
      ref={sheet}
    >
      <div className="row-title">{title}</div>
      <div className="row-help selectable" data-looks-source="">
        {t("settingsPage.looksGallery.consentSource", card.source.reference, shortCommit(card.source.commit))}
      </div>
      {!card.reviewed && <div className="row-help looks-unreviewed">{t("settingsPage.looksGallery.notReviewed")}</div>}
      {card.setup.description && <div className="row-help selectable">{card.setup.description}</div>}
      <div className="row-help">{t("settingsPage.looksGallery.changes")}</div>
      {lines.length === 0 ? (
        <div className="row-help">{t("settingsPage.looksGallery.change.nothing")}</div>
      ) : (
        <ul className="looks-changes selectable">
          {lines.map((line, index) => (
            <li key={`${line.kind}-${index}`} data-looks-change={line.kind}>
              {line.text}
              {line.replaces && (
                <span className="looks-replaces"> · {t("settingsPage.looksGallery.replacesYours")}</span>
              )}
            </li>
          ))}
        </ul>
      )}
      {card.setup.requires && (
        <div className="row-help">{t("settingsPage.looksGallery.requires", card.setup.requires)}</div>
      )}
      <div className="accounts-buttons">
        <Button
          variant="solid"
          className="button"
          data-looks-action="confirmInstall"
          // The name UI drivers match (the feature-flows looks row waits on an
          // AXButton named "Install"): WebKit exposes text-only buttons as
          // AXTitle, which exact-label matching skips. The tiles' Install
          // buttons carry aria-label for the same reason.
          aria-label={
            busy === card.setup.id ? t("settingsPage.looksGallery.installing") : t("settingsPage.looksGallery.install")
          }
          disabled={busy !== null}
          onClick={() => onConfirm(card)}
        >
          {busy === card.setup.id ? t("settingsPage.looksGallery.installing") : t("settingsPage.looksGallery.install")}
        </Button>
        <Button className="button" data-looks-action="cancel" onClick={onCancel}>
          {t("settingsPage.cancel")}
        </Button>
      </div>
    </div>
  );
}

/** Uninstall asks first, inline, with what goes back. */
function RemoveSheet({
  layer,
  busy,
  onConfirm,
  onCancel,
}: {
  layer: LookLayer;
  busy: string | null;
  onConfirm: (layer: LookLayer) => void;
  onCancel: () => void;
}) {
  const sheet = useRef<HTMLDivElement>(null);
  const title = t("settingsPage.looksGallery.removeTitle", layer.name);
  useLayoutEffect(() => {
    sheet.current?.scrollIntoView?.({ block: "nearest" });
    focusRoute(
      sheet.current?.querySelector<HTMLButtonElement>('[data-looks-action="cancel"]'),
      "person",
      "the person's Uninstall opened the confirmation: Cancel",
    );
  }, [layer]);
  return (
    <div
      className="accounts-form looks-sheet"
      data-looks-confirm={layer.id}
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
      role="group"
      aria-label={title}
      ref={sheet}
    >
      <div className="row-title">{title}</div>
      <div className="row-help">{t("settingsPage.looksGallery.removeBody")}</div>
      <div className="accounts-buttons">
        <Button
          danger
          variant="ghost"
          className="button"
          data-looks-action="confirmRemove"
          disabled={busy !== null}
          onClick={() => onConfirm(layer)}
        >
          {t("settingsPage.looksGallery.uninstall")}
        </Button>
        <Button className="button" data-looks-action="cancel" onClick={onCancel}>
          {t("settingsPage.cancel")}
        </Button>
      </div>
    </div>
  );
}

/** Every installed look, top first (looks from outside the gallery too): its switch, its order and
 * Uninstall. Where two that are on set the same thing, the higher one wins. */
export function StackedLooks({
  stack,
  busy,
  actions,
}: {
  stack: readonly LookLayer[];
  busy: string | null;
  actions: LooksActions;
}) {
  const ids = stack.map((layer) => layer.id);
  return (
    <div className="looks-stacked" data-looks-stacked="">
      <h4 className="group-title">{t("settingsPage.looksGallery.stacked")}</h4>
      <div className="rows">
        <div className="row">
          <span className="row-help">{t("settingsPage.looksGallery.stackedHelp")}</span>
        </div>
        {stack.map((layer) => (
          <StackedRow
            key={layer.id}
            layer={layer}
            canUp={moveOrder(ids, layer.id, -1) !== null}
            canDown={moveOrder(ids, layer.id, 1) !== null}
            busy={busy}
            actions={actions}
          />
        ))}
      </div>
    </div>
  );
}

function StackedRow({
  layer,
  canUp,
  canDown,
  busy,
  actions,
}: {
  layer: LookLayer;
  canUp: boolean;
  canDown: boolean;
  busy: string | null;
  actions: LooksActions;
}) {
  const labelId = useId();
  const waiting = busy !== null;
  return (
    <div className="row looks-layer" data-looks-layer={layer.id} data-on={layer.on ? "" : undefined}>
      <div className="row-main">
        <span className="looks-position row-help">{layer.position}</span>
        <div className="row-label">
          <div className="row-title" id={labelId}>
            {layer.name}
          </div>
          <div className="row-help looks-source selectable">
            {layer.catalog ? layer.source : t("settingsPage.looksGallery.outsideGallery", layer.source)}
          </div>
        </div>
        <span className="row-control looks-controls">
          <LayerButton
            icon="chevron"
            iconClass="icon-up"
            action={t("settingsPage.moveUp")}
            layer={layer.name}
            data="up"
            disabled={waiting || !canUp}
            onClick={() => actions.onMove(layer.id, -1)}
          />
          <LayerButton
            icon="chevron"
            action={t("settingsPage.moveDown")}
            layer={layer.name}
            data="down"
            disabled={waiting || !canDown}
            onClick={() => actions.onMove(layer.id, 1)}
          />
          <LayerButton
            icon="xmark"
            action={t("settingsPage.looksGallery.uninstall")}
            layer={layer.name}
            data="remove"
            disabled={waiting}
            onClick={() => actions.onRemove(layer)}
          />
          <Switch
            checked={layer.on}
            disabled={waiting}
            labelId={labelId}
            onToggle={(next) => actions.onToggle(layer.id, next)}
          />
        </span>
      </div>
    </div>
  );
}

function LayerButton({
  icon,
  iconClass,
  action,
  layer,
  data,
  disabled,
  onClick,
}: {
  icon: string;
  iconClass?: string;
  action: string;
  layer: string;
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
      aria-label={`${action}: ${layer}`}
      title={action}
      disabled={disabled}
      data-looks-action={data}
      onClick={onClick}
    >
      <Icon name={icon} className={iconClass} />
    </Button>
  );
}
