// The update surfaces as their own documents (cx-urd.61.2): the host opens the changelog bundle on
// `#/surface/ready` (the staged update card's highlights popover) or `#/surface/updated` (the
// "cmux Updated!" card) in a small transparent page view, draws the material around it, and sizes
// itself to the height this page reports. Data: `cmux.changelog.surface.get` and the stream
// `cmux.changelog.surface.changes` (UpdateHighlights, or null while there is nothing to show).
import { createRoot } from "react-dom/client";
import type { PageClient } from "../shared/pageClient";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import type { UpdateHighlights, UpdateSurfaceActions } from "./updateHighlights";
import { UpdatedCard, UpdateReadyHighlights } from "./UpdateSurfaces";
import "../shared/pageBase.css";
import "./updateSurfaces.css";
import "./surface.css";

export type SurfaceKind = "ready" | "updated";

export const SurfaceOps = {
  get: "cmux.changelog.surface.get",
  size: "cmux.changelog.surface.size",
  openChangelog: "cmux.changelog.surface.openChangelog",
  dismiss: "cmux.changelog.surface.dismiss",
  stream: "cmux.changelog.surface.changes",
} as const;

/** `#/surface/ready` -> "ready"; null for any other route. */
export function parseSurface(hash: string): SurfaceKind | null {
  const match = /^#\/surface\/(ready|updated)\b/.exec(hash);
  return match ? (match[1] as SurfaceKind) : null;
}

export function mountUpdateSurface(root: HTMLElement, kind: SurfaceKind, client: PageClient | null): void {
  const strings = createStrings(table);
  document.documentElement.lang = strings.language;
  document.documentElement.dataset.surface = kind;
  const call = (op: string, params: unknown = {}) => void client?.call(op, params).catch(() => undefined);
  const actions: UpdateSurfaceActions =
    kind === "updated"
      ? {
          openChangelog: () => call(SurfaceOps.openChangelog),
          dismiss: () => call(SurfaceOps.dismiss),
        }
      : { openChangelog: () => call(SurfaceOps.openChangelog) };
  const react = createRoot(root);
  const render = (data: UpdateHighlights | null) =>
    react.render(
      data === null ? null : kind === "ready" ? (
        <UpdateReadyHighlights data={data} strings={strings} actions={actions} />
      ) : (
        <UpdatedCard data={data} strings={strings} actions={actions} />
      ),
    );
  // The host sizes the popover or the card slot to the content; 0 while there is nothing.
  let reported = -1;
  new ResizeObserver(() => {
    const height = Math.ceil(root.getBoundingClientRect().height);
    if (height === reported) return;
    reported = height;
    call(SurfaceOps.size, { height });
  }).observe(root);
  if (!client) return;
  void client.call<UpdateHighlights | null>(SurfaceOps.get, {}).then(render, () => render(null));
  void client.subscribe<UpdateHighlights | null>(SurfaceOps.stream, (data) => render(data));
}
