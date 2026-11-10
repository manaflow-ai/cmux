import type { MountRequest, MountSurface } from "../../apps/scene/panelsClient";

const SURFACES: readonly string[] = [
  "pane",
  "sidebarSection",
  "hoverCard",
  "sessionInfoSection",
] satisfies MountSurface[];

/** The mount a page route names: `#/?app=<id>[&surface=<surface>][&section=<id>]`. The surface is the
 * app pane unless the route names another; the host resolves the app's implementation for it
 * (`AppMountSurface`). Undefined for a route with no app or an unknown surface. */
export function appSceneRoute(hash: string): MountRequest | undefined {
  const query = hash.indexOf("?");
  if (query < 0) return undefined;
  const params = new URLSearchParams(hash.slice(query + 1));
  const app = params.get("app");
  const surface = params.get("surface") ?? "pane";
  if (!app || !SURFACES.includes(surface)) return undefined;
  const section = params.get("section");
  return { surface: surface as MountSurface, app, ...(section && { section }), context: {} };
}
