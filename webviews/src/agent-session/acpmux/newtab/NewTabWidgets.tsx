// The New Tab widget grid (`cmux.widget/1`), drawn as Apple draws widgets: a grid of tiles on one
// unit (small 1x1, medium 2x1, large 2x2), each a rounded card around the widget's own scene (the
// SDK's WidgetFrame draws the 16 pt content inset; the card draws the shape). The person places,
// sizes, moves and removes them in edit mode (Edit Widgets); the layout, the sizes a widget may take
// and its refresh budget are the daemon's (AppWidgetsClient), and every open page follows an edit.
//
// Cost: nothing mounts while no tile is placed. The page lists widgets once (and again only on
// `apps-widgets-changed`); with none installed and none placed it draws nothing at all. A tile out
// of view or on a hidden page is reported hidden, so its widget gets no ticks.
//
// Let it crash: a tile whose widget threw keeps its last scene, dimmed, with "Updating..." while the
// daemon mounts it again; a tile whose app is gone says so in its own card. No tile's state touches
// another, and the page around the grid is never blanked.
import { useEffect, useMemo, useRef, useState, useSyncExternalStore } from "react";
import { appPanelsDevClient } from "../../../apps/scene/panelsClient";
import { SceneRenderer } from "../../../apps/scene/SceneRenderer";
import { observeTileVisibility } from "../../../apps/scene/widgetVisibility";
import {
  AppWidgetsClient,
  type WidgetInfo,
  type WidgetMeter,
  type WidgetsView,
  type WidgetTileMount,
  type WidgetTilePlacement,
} from "../../../apps/scene/widgetsClient";
import type { PageClient } from "../../../pages/shared/pageClient";
import { Icon } from "../icons/Icon";
import { pageHostClient } from "../pageHost";
import { AddWidgetGallery, type AddWidgetLook } from "./AddWidgetGallery";
import { useNt } from "./strings";
import { GridWidgetFrame, type WidgetEditLook } from "./WidgetEditing";
import { moveEdit, useWidgetEditing } from "./widgetEditingModel";
import "./widgets.css";

/// The tile card: translucent material over the page (glass, macOS Sonoma's desktop widgets), an
/// opaque card (solid, the iPad Home Screen), or the accent-tinted material (tinted, Sonoma's widgets
/// behind a window).
export type WidgetTileLook = "glass" | "solid" | "tinted";

const NOOP_SUBSCRIBE = () => () => undefined;
const EMPTY: WidgetsView = { supported: false, listed: false, widgets: [], tiles: [] };
const EMPTY_READ = () => EMPTY;
/// While edit mode shows the meter, it reads the daemon's counts this often.
const METER_MS = 5000;

/** The page's widgets in the New Tab place. `injected` is the gallery's or a test's host. */
export function useNewTabWidgets(injected?: PageClient | null) {
  const client = injected === undefined ? (pageHostClient() ?? appPanelsDevClient()) : injected;
  const owner = useMemo(() => (client ? new AppWidgetsClient(client, "newtab") : undefined), [client]);
  const view = useSyncExternalStore(
    owner?.subscribe ?? NOOP_SUBSCRIBE,
    owner?.getView ?? EMPTY_READ,
    owner?.getView ?? EMPTY_READ,
  );
  useEffect(() => {
    if (!owner) return;
    owner.start();
    const stop = () => owner.stop();
    // Native pane retirement can discard the document without unmounting React first.
    globalThis.addEventListener?.("pagehide", stop);
    return () => {
      globalThis.removeEventListener?.("pagehide", stop);
      owner.stop();
    };
  }, [owner]);
  return { client, owner, view };
}

export function NewTabWidgets({
  client: injected,
  tileLook = "glass",
  editLook = "badge",
  galleryLook = "rows",
  initialEditing = false,
  initialGallery = false,
}: {
  client?: PageClient | null;
  tileLook?: WidgetTileLook;
  editLook?: WidgetEditLook;
  galleryLook?: AddWidgetLook;
  /// The gallery's states: edit mode or the Add Widget sheet open from the start.
  initialEditing?: boolean;
  initialGallery?: boolean;
}) {
  const nt = useNt();
  const { client, owner, view } = useNewTabWidgets(injected);
  const editing = useWidgetEditing(initialEditing);
  const [gallery, setGallery] = useState(initialGallery);
  const meters = useMeters(owner, editing.editing, view.tiles);
  // An older host, or nothing installed and nothing placed: no grid and no affordance.
  if (!owner || !view.supported || (view.widgets.length === 0 && view.tiles.length === 0)) return null;
  const byApp = new Map(view.widgets.map((widget) => [widget.app, widget]));
  const order = view.tiles.map((tile) => tile.instance);
  return (
    <section
      className="nt-widgets"
      aria-label={nt("widgets.label")}
      data-look={tileLook}
      data-editing={editing.editing || undefined}
    >
      {view.tiles.length > 0 && (
        <div className="nt-widget-grid">
          {view.tiles.map((placement) => {
            const info = byApp.get(placement.app);
            const label = info?.title ?? placement.app;
            const tile = <WidgetTile key={placement.instance} owner={owner} placement={placement} label={label} />;
            if (!editing.editing) return tile;
            const meter = meters.get(placement.instance);
            return (
              <GridWidgetFrame
                key={placement.instance}
                id={placement.instance}
                label={label}
                order={order}
                size={placement.size}
                sizes={info?.sizes ?? [placement.size]}
                look={editLook}
                meter={meter && meterLine(nt, meter)}
                onRemove={() => void owner.edit({ op: "remove", instance: placement.instance })}
                onMove={(instance, next) => {
                  const edit = moveEdit(order, next, instance);
                  if (edit) void owner.edit(edit);
                }}
                onResize={(size) => void owner.edit({ op: "resize", instance: placement.instance, size })}
              >
                {tile}
              </GridWidgetFrame>
            );
          })}
        </div>
      )}
      <div className="nt-widget-bar">
        {editing.editing ? (
          <>
            <button
              type="button"
              className="nt-widget-bar-button ui-btn"
              data-edit="add"
              onClick={() => setGallery(true)}
            >
              <Icon name="action.add" size={12} />
              <span>{nt("widgets.add")}</span>
            </button>
            <button
              type="button"
              className="nt-widget-bar-button ui-btn"
              data-edit="done"
              data-primary=""
              onClick={() => editing.setEditing(false)}
            >
              {nt("widgets.done")}
            </button>
          </>
        ) : (
          <button
            type="button"
            className="nt-widget-bar-button ui-btn"
            data-edit="start"
            onClick={() => editing.setEditing(true)}
          >
            {nt("widgets.edit")}
          </button>
        )}
      </div>
      {gallery && (
        <AddWidgetGallery
          open
          onOpenChange={setGallery}
          widgets={view.widgets}
          client={client}
          look={galleryLook}
          onAdd={(widget: WidgetInfo, size) => {
            void owner.edit({ op: "add", app: widget.app, size });
            setGallery(false);
            editing.setEditing(true);
          }}
        />
      )}
    </section>
  );
}

/** One placed widget: its scene in the tile card, kept and dimmed while it is stale. */
export function WidgetTile({
  owner,
  placement,
  label,
}: {
  owner: AppWidgetsClient;
  placement: WidgetTilePlacement;
  label: string;
}) {
  const tile = owner.tile(placement.instance);
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const element = ref.current;
    if (!element || !tile) return;
    return observeTileVisibility(element, tile);
  }, [tile]);
  if (!tile) return null;
  return (
    <div ref={ref} className="nt-widget-tile" data-size={placement.size} data-app={placement.app}>
      <TileBody tile={tile} label={label} />
    </div>
  );
}

function TileBody({ tile, label }: { tile: WidgetTileMount; label: string }) {
  const nt = useNt();
  const store = tile.mount.store;
  const status = useSyncExternalStore(store.subscribeStatus, store.getStatus, store.getStatus);
  const health = useSyncExternalStore(tile.subscribeHealth, tile.getHealth, tile.getHealth);
  const failed = status.state === "failed";
  const stale = health.stale || status.state === "disconnected";
  return (
    <section
      className="nt-widget-card"
      data-size={tile.placement.size}
      data-status={status.state}
      data-stale={stale || undefined}
      aria-label={label}
      aria-busy={status.state === "loading"}
    >
      {failed ? (
        <output className="nt-widget-notice">
          <Icon name="status.attention" size={12} />
          <span>{nt("widgets.unavailable", { name: label })}</span>
        </output>
      ) : (
        <SceneRenderer store={store} dispatch={tile.mount.dispatch} resolveAsset={tile.mount.resolveAsset} />
      )}
      {stale && !failed && (
        <output className="nt-widget-stale" title={health.reason}>
          {nt("widgets.updating")}
        </output>
      )}
    </section>
  );
}

function meterLine(nt: ReturnType<typeof useNt>, meter: WidgetMeter): string {
  const values = { ticks: String(meter.ticks), held: String(meter.held) };
  return meter.everySeconds
    ? nt("widgets.meter", { ...values, every: String(meter.everySeconds) })
    : nt("widgets.meter.static", values);
}

/** The edit mode's meter, by tile: read on entering edit mode and every few seconds while in it. */
function useMeters(
  owner: AppWidgetsClient | undefined,
  editing: boolean,
  tiles: readonly WidgetTilePlacement[],
): ReadonlyMap<string, WidgetMeter> {
  const [meters, setMeters] = useState<ReadonlyMap<string, WidgetMeter>>(new Map());
  const count = tiles.length;
  useEffect(() => {
    if (!owner || !editing || count === 0) return;
    let live = true;
    const read = () =>
      void owner.meters().then((rows) => {
        if (live) setMeters(new Map(rows.map((row) => [row.instance, row])));
      });
    read();
    const timer = setInterval(read, METER_MS);
    return () => {
      live = false;
      clearInterval(timer);
    };
  }, [owner, editing, count]);
  return meters;
}
