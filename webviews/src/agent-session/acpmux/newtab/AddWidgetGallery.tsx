// The Add Widget gallery (Apple's widget gallery): every installed widget for the New Tab
// (`apps.widgets.list {place:"newtab"}`), each drawn live at each of its sizes. A preview mounts the
// widget with `context.preview: true`, so it draws sample data and writes nothing; the previews
// mount only while the sheet is open. Picking one adds it at that size (`apps.widgets.layout.edit
// {op:add}`), at the end of the grid.
import { useEffect, useMemo, useState, useSyncExternalStore } from "react";
import { AppSceneMount } from "../../../apps/scene/appSceneMount";
import { SceneRenderer } from "../../../apps/scene/SceneRenderer";
import { type WidgetInfo, type WidgetSize, widgetLocaleContext } from "../../../apps/scene/widgetsClient";
import type { PageClient } from "../../../pages/shared/pageClient";
import { DialogTitle } from "../../../ui/Dialog";
import { Sheet } from "../../../ui/Sheet";
import { Icon } from "../icons/Icon";
import { useNt } from "./strings";
import { useSizeName } from "./WidgetEditing";

/// The gallery's arrangement: every size of each widget in a row (rows, macOS's gallery), one size
/// at a time with size chips (sizes, iOS's), or every preview in one tile grid (grid, the Lock
/// Screen sheet).
export type AddWidgetLook = "rows" | "sizes" | "grid";

/** A widget drawn live from sample data (`context.preview`), for the gallery only. */
export function WidgetPreview({
  client,
  widget,
  size,
}: {
  client: PageClient | null;
  widget: WidgetInfo;
  size: WidgetSize;
}) {
  const mount = useMemo(
    () =>
      new AppSceneMount(client, "widget", widget.app, {
        place: "newtab",
        size,
        instance: `preview-${size}`,
        preview: true,
        ...widgetLocaleContext(),
      }),
    [client, widget.app, size],
  );
  useEffect(() => {
    mount.start();
    return () => mount.stop();
  }, [mount]);
  const status = useSyncExternalStore(mount.store.subscribeStatus, mount.store.getStatus, mount.store.getStatus);
  return (
    <div className="nt-widget-card" data-size={size} data-status={status.state}>
      {status.state !== "failed" && status.state !== "disconnected" && (
        <SceneRenderer store={mount.store} dispatch={() => undefined} resolveAsset={mount.resolveAsset} />
      )}
    </div>
  );
}

export function AddWidgetGallery({
  open,
  onOpenChange,
  widgets,
  client,
  look = "rows",
  onAdd,
}: {
  open: boolean;
  onOpenChange(open: boolean): void;
  widgets: readonly WidgetInfo[];
  client: PageClient | null;
  look?: AddWidgetLook;
  /// Called from the click itself (the host checks the gesture).
  onAdd(widget: WidgetInfo, size: WidgetSize): void;
}) {
  const nt = useNt();
  // The sheet role's glass (ui/popupSurface.css `.ui-dialog.ui-glass`: the sheet veil, its blur, radius and
  // depth), as the paste sheet has: the shipped pane loads no ui.css, whose `.ui-sheet` fill never
  // reaches it, and the New Tab composer read through the bare sheet.
  return (
    <Sheet
      open={open}
      onOpenChange={onOpenChange}
      label={nt("widgets.add")}
      className="ui-glass ui-glass-floats nt-widget-gallery"
      side="bottom"
    >
      <div className="nt-widget-gallery-body" data-look={look}>
        <div className="nt-widget-gallery-head">
          <DialogTitle className="nt-widget-gallery-title">{nt("widgets.add")}</DialogTitle>
          <button type="button" className="nt-widget-gallery-done ui-btn" onClick={() => onOpenChange(false)}>
            {nt("widgets.done")}
          </button>
        </div>
        {/* The rows scroll here, under the title and Done, at any window height (cmux#44995). */}
        <div className="nt-widget-gallery-scroll">
          {widgets.length === 0 ? (
            <p className="nt-widget-gallery-empty">{nt("widgets.gallery.empty")}</p>
          ) : look === "grid" ? (
            <div className="nt-widget-gallery-grid">
              {widgets.flatMap((widget) =>
                widget.sizes.map((size) => (
                  <PreviewButton
                    key={`${widget.app}:${size}`}
                    widget={widget}
                    size={size}
                    client={client}
                    onAdd={onAdd}
                  />
                )),
              )}
            </div>
          ) : (
            <ul className="nt-widget-gallery-list">
              {widgets.map((widget) => (
                <GalleryRow key={widget.app} widget={widget} client={client} look={look} onAdd={onAdd} />
              ))}
            </ul>
          )}
        </div>
      </div>
    </Sheet>
  );
}

function GalleryRow({
  widget,
  client,
  look,
  onAdd,
}: {
  widget: WidgetInfo;
  client: PageClient | null;
  look: AddWidgetLook;
  onAdd(widget: WidgetInfo, size: WidgetSize): void;
}) {
  const sizeName = useSizeName();
  const [picked, setPicked] = useState<WidgetSize>(widget.defaultSize);
  const sizes = look === "sizes" ? [picked] : widget.sizes;
  return (
    <li className="nt-widget-gallery-row">
      <div className="nt-widget-gallery-meta">
        <span className="nt-widget-gallery-name">{widget.title}</span>
        {widget.description && <span className="nt-widget-gallery-description">{widget.description}</span>}
        {look === "sizes" && widget.sizes.length > 1 && (
          // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
          <div className="nt-widget-chips" role="group">
            {widget.sizes.map((size) => (
              <button
                key={size}
                type="button"
                className="nt-widget-chip"
                aria-pressed={size === picked}
                onClick={() => setPicked(size)}
              >
                {sizeName(size)}
              </button>
            ))}
          </div>
        )}
      </div>
      <div className="nt-widget-gallery-previews">
        {sizes.map((size) => (
          <PreviewButton key={size} widget={widget} size={size} client={client} onAdd={onAdd} />
        ))}
      </div>
    </li>
  );
}

function PreviewButton({
  widget,
  size,
  client,
  onAdd,
}: {
  widget: WidgetInfo;
  size: WidgetSize;
  client: PageClient | null;
  onAdd(widget: WidgetInfo, size: WidgetSize): void;
}) {
  const nt = useNt();
  const sizeName = useSizeName();
  const label = `${nt("widgets.add")}: ${widget.title}, ${sizeName(size)}`;
  return (
    <button
      type="button"
      className="nt-widget-preview"
      data-app={widget.app}
      data-size={size}
      aria-label={label}
      title={label}
      onClick={() => onAdd(widget, size)}
    >
      <span className="nt-widget-preview-frame" inert>
        <WidgetPreview client={client} widget={widget} size={size} />
      </span>
      <span className="nt-widget-preview-add" aria-hidden="true">
        <Icon name="action.add" size={12} />
      </span>
    </button>
  );
}
