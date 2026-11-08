// Boots the browser toolbar row (`cmux-page://cmux.browser-toolbar/`), one per browser pane (and
// per popup window), hosted by CmuxNextBrowser BrowserToolbarWebView through CmuxNextPages
// BrowserChromeWebHost. The host pushes `cmux.browser-toolbar.state` (browser-chrome/toolbar/wire.ts);
// the page draws the row and runs the omnibar (browser-chrome/toolbar/session.ts), and sends every
// command on `cmux.browser-toolbar.command`.
import "../shared/desktop";
import { useEffect, useLayoutEffect, useRef, useState, useSyncExternalStore, type CSSProperties } from "react";
import { createRoot } from "react-dom/client";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { setDocumentLanguage, type Strings } from "../shared/i18n";
import { UiProvider, languageDirection } from "../../ui/UiProvider";
import { BrowserToolbar } from "../../browser-chrome/ui/BrowserToolbar";
import { toolbarStrings } from "../../browser-chrome/ui/strings";
import { resolveLayout, type BrowserToolbarCommand } from "../../browser-chrome/ui/toolbarModel";
import { OmniboxField } from "../../browser-chrome/toolbar/OmniboxField";
import { ToolbarSession } from "../../browser-chrome/toolbar/session";
import { barFills, chipFor, starFor, wireCommand } from "../../browser-chrome/toolbar/view";
import { TOOLBAR_PAGE, type OmnibarLookWire, type ToolbarHostState } from "../../browser-chrome/toolbar/wire";
import "../../ui/ui.css";
import "../shared/pageBase.css";
import "./styles.css";

/** The bar's fills (`browser.omnibar.glass`, `backgroundOpacity`): `barFills`. */
function lookStyle(look: OmnibarLookWire): CSSProperties {
  const { fill, hover } = barFills(look);
  return { "--bc-bar-fill": fill, "--bc-bar-hover": hover } as CSSProperties;
}

function useViewportWidth(): number {
  const [width, setWidth] = useState(() => window.innerWidth);
  useEffect(() => {
    const update = () => setWidth(window.innerWidth);
    window.addEventListener("resize", update);
    return () => window.removeEventListener("resize", update);
  }, []);
  return width;
}

function ToolbarRow({ session, strings }: { session: ToolbarSession; strings: Strings }) {
  const { host, state, presentation, chipDrag } = useSyncExternalStore(session.subscribe, session.getSnapshot);
  const width = useViewportWidth();
  const row = useRef<HTMLDivElement>(null);
  const layout = host
    ? resolveLayout(width, host.buttons, host.extensions.pinned.length, host.extensions.shows, host.metrics)
    : null;
  // After each render: where the controls are, sent only when something moved.
  useLayoutEffect(() => {
    if (!row.current || !layout) return;
    session.reportLayout(row.current, {
      showsForward: layout.showsForward,
      visiblePinned: layout.visiblePinned,
      collapse: layout.collapse,
    });
  });
  if (!host || !layout) return null;
  const metrics = host.metrics;
  const send = (command: BrowserToolbarCommand) => {
    const wire = wireCommand(command);
    if (wire) session.post(wire);
  };
  return (
    <div ref={row} className="btp-row" style={{ top: metrics.barTop, height: metrics.bar }}>
      <BrowserToolbar
        navigation={host.navigation}
        omnibar={{
          text: presentation.text,
          chip: chipFor(host.site, presentation.chip),
          bookmark: starFor(host.bookmark, state.phase),
          editing: presentation.hasFocus,
          suggestionsOpen: presentation.rows.length > 0,
          upward: host.omnibar.upward,
          pageInfoOpen: host.pageInfoOpen,
        }}
        extensions={{ shows: host.extensions.shows, pinned: host.extensions.pinned }}
        extensionPressed={host.extensions.pressed}
        extensionsPressed={host.extensions.extensionsPressed}
        extensionsCrashed={host.extensions.crashed}
        resolvedButtons={host.buttons}
        metrics={metrics}
        layout={layout}
        badges={host.badges}
        showsButtons={host.showsButtons}
        showsProgress={false}
        holdsFieldFocus
        look="flat"
        strings={strings}
        style={lookStyle(host.look)}
        field={
          <OmniboxField
            inputRef={session.attachInput}
            presentation={presentation}
            placeholder={strings.t("browser.omnibar.placeholder")}
          />
        }
        onFieldMouseDown={session.fieldMouseDown}
        chipDrag={chipDrag}
        onCommand={send}
      />
    </div>
  );
}

export function mountBrowserToolbarPage(root: HTMLElement, client: PageClient): () => void {
  const session = new ToolbarSession((command) => void client.call(`${TOOLBAR_PAGE}.command`, command));
  const unsubscribe = client.subscribe<ToolbarHostState>(`${TOOLBAR_PAGE}.state`, (next) =>
    session.applyHostState(next),
  );
  const strings = toolbarStrings();
  setDocumentLanguage(strings.language);
  const react = createRoot(root);
  react.render(
    <UiProvider container={root} dir={languageDirection(strings.language)}>
      <ToolbarRow session={session} strings={strings} />
    </UiProvider>,
  );
  return () => {
    void unsubscribe.then((stop) => stop());
    react.unmount();
  };
}

const root = document.getElementById("root");
const client = createPageClient();
if (root && client && document.documentElement.dataset.cmuxPage === "browser-toolbar") {
  mountBrowserToolbarPage(root, client);
}
