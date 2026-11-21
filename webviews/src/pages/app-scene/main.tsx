// Boots an app's pane (`cmux-page://cmux.app-scene/#/?app=<id>`): the one scene the route names,
// mounted through the host's `cmux.apps.panels.*` (CmuxNextAgentPane AppsPanelsPageProvider, which
// AppPanePage routes this page to). The mount ends when the page goes away. In the browser dev loop
// (`/app-scene/?mock#/?app=samples/github-prs`) the panels mock stands in for the host.
// DESKTOP-FEEL (R139): the shared desktop layer loads first.
import "../shared/desktop";
// Before any part that reads the pane's table: the failure row's keys.
import "./paneStrings";
import { createRoot } from "react-dom/client";
import { currentLanguage } from "../../agent-session/acpmux/i18n";
import { AppSceneMount } from "../../apps/scene/panelsClient";
import { MockAppPanelsClient } from "../../apps/scene/panelsMock";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { appPopupHost } from "../shared/pagePopupHost";
import { UiProvider, languageDirection } from "../../ui/UiProvider";
import { AppScenePage } from "./AppScenePage";
import { appSceneRoute } from "./route";
import "../../ui/ui.css";
import "../shared/pageBase.css";
import "./styles.css";

/** Draws the page in `root` and mounts the route's scene; returns the mount (undefined when the route
 * names no app or there is no host). */
export function mountAppScenePage(
  root: HTMLElement,
  client: PageClient | null = defaultClient(),
  hash: string = location.hash,
): AppSceneMount | undefined {
  const request = appSceneRoute(hash);
  const mount = client && request ? new AppSceneMount(client, request) : undefined;
  createRoot(root).render(
    <UiProvider container={root} popupHost={appPopupHost(client)} dir={languageDirection(currentLanguage())}>
      <AppScenePage mounted={mount} />
    </UiProvider>,
  );
  if (mount) {
    void mount.start();
    // The host also ends the page's mounts when it closes; this ends them for a reload too.
    window.addEventListener("pagehide", () => mount.release(), { once: true });
  }
  return mount;
}

function defaultClient(): PageClient | null {
  const mock = new URLSearchParams(location.search).has("mock");
  return createPageClient(mock ? () => new MockAppPanelsClient() : undefined);
}

const root = document.getElementById("root");
if (root && document.documentElement.dataset.cmuxPage === "app-scene") mountAppScenePage(root);
