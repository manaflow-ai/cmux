// Gallery-only host answers for the real reply chips, images and preview-card menu.
import type { ChipHostFixture } from "../format";
import { resetLinkStore, seedLinkStore } from "../../agent-session/acpmux/chips/linkStore";
import { setChipHost } from "../../agent-session/acpmux/chips/host";

/** Install one public-safe fixture for the agent pane's host-backed reply affordances. */
export function installChipHost(fixture: ChipHostFixture | undefined): void {
  resetLinkStore();
  if (!fixture) {
    setChipHost(undefined);
    return;
  }
  setChipHost(async (method, params) => {
    if (method === "link.inspect") {
      const paths = (params.paths as string[] | undefined) ?? [];
      const urls = (params.urls as string[] | undefined) ?? [];
      return {
        paths: Object.fromEntries(
          paths.flatMap((path) => (fixture.paths?.[path] ? [[path, fixture.paths[path]]] : [])),
        ),
        sites: Object.fromEntries(urls.flatMap((url) => (fixture.sites?.[url] ? [[url, fixture.sites[url]]] : []))),
        ...(fixture.policy ? { policy: fixture.policy } : {}),
      };
    }
    if (method === "image.load") {
      const src = params.src;
      const data = typeof src === "string" ? fixture.images?.[src] : undefined;
      return typeof data === "string" ? { src: data } : null;
    }
    if (method === "browser.list") return { browsers: fixture.browsers ?? [] };
    return null;
  });
  seedLinkStore({ paths: fixture.paths, sites: fixture.sites, policy: fixture.policy });
}
