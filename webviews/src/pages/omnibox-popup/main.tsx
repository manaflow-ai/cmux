// Boots the omnibar's suggestion card (`cmux-page://cmux.omnibox-popup/`), in its own panel under
// the bar (CmuxNextBrowser through CmuxNextPages BrowserChromeWebHost). It only draws the rows the
// toolbar page decided and reports the pointer: hovers (with the pointer in screen points, so a
// row that slides under a still pointer is no hover) and picks with their modifiers. Rows never take
// focus; the field keeps it. After each state it reports the card's height for the panel.
import "../shared/desktop";
import { useLayoutEffect, useRef, useSyncExternalStore } from "react";
import { createRoot } from "react-dom/client";
import { createPageClient, type PageClient } from "../shared/pageClient";
import { setDocumentLanguage } from "../shared/i18n";
import { UiProvider, languageDirection } from "../../ui/UiProvider";
import {
  MAX_SUGGESTIONS,
  SuggestionDropdown,
  type SuggestionCommand,
} from "../../browser-chrome/ui/SuggestionDropdown";
import { toolbarStrings } from "../../browser-chrome/ui/strings";
import { POPUP_PAGE, type PopupHostState, type PopupPageCommand } from "../../browser-chrome/toolbar/wire";
import "../../ui/ui.css";
import "../shared/pageBase.css";
import "./styles.css";

export function mountOmniboxPopupPage(root: HTMLElement, client: PageClient): () => void {
  let model: PopupHostState | null = null;
  const listeners = new Set<() => void>();
  const store = {
    subscribe: (listener: () => void) => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    get: () => model,
  };
  const unsubscribe = client.subscribe<PopupHostState>(`${POPUP_PAGE}.state`, (next) => {
    model = next;
    for (const listener of listeners) listener();
  });
  const send = (command: PopupPageCommand) => void client.call(`${POPUP_PAGE}.command`, command);
  // The last pointer location, in screen points: hovers carry it.
  let pointer = { x: 0, y: 0 };
  const track = (event: PointerEvent) => {
    pointer = { x: event.screenX, y: event.screenY };
  };
  window.addEventListener("pointermove", track, true);
  window.addEventListener("pointerdown", track, true);
  // Rows never take focus: the field in the toolbar keeps the keys.
  const keepFocus = (event: MouseEvent) => event.preventDefault();
  window.addEventListener("mousedown", keepFocus, true);

  const strings = toolbarStrings();
  setDocumentLanguage(strings.language);
  const label = strings.t("browser.omnibar.placeholder");

  function Card() {
    const current = useSyncExternalStore(store.subscribe, store.get);
    const card = useRef<HTMLDivElement>(null);
    // After each committed state: the card's height (its margin excluded: the panel adds it).
    useLayoutEffect(() => {
      if (!current || !card.current) return;
      const shown = card.current.querySelector(".bc-suggestions");
      const height = shown ? Math.ceil(shown.getBoundingClientRect().height) : 0;
      void client.call(`${POPUP_PAGE}.size`, { height, revision: current.revision });
    }, [current]);
    if (!current) return null;
    const [top, right, bottom, left] = current.margin;
    const onCommand = (command: SuggestionCommand) => {
      // Each names the rows of the state drawn now (`revision`): the host drops one for rows it replaced.
      const revision = current.revision;
      if (command.type === "hover") send({ type: "hover", index: command.index, pointer, revision });
      else send({ ...command, revision });
    };
    return (
      <div ref={card} className="op-card" style={{ padding: `${top}px ${right}px ${bottom}px ${left}px` }}>
        {current.rows.length > 0 && (
          <SuggestionDropdown
            suggestions={current.rows.slice(0, MAX_SUGGESTIONS)}
            highlighted={current.highlighted}
            onCommand={onCommand}
            look="joined"
            upward={current.upward}
            maxHeight={current.maxHeight}
            label={label}
            metrics={{
              bar: current.metrics.bar,
              cornerRadius: current.cornerRadius,
              fontSize: current.metrics.fontSize,
            }}
          />
        )}
      </div>
    );
  }
  const react = createRoot(root);
  react.render(
    <UiProvider container={root} dir={languageDirection(strings.language)}>
      <Card />
    </UiProvider>,
  );
  return () => {
    window.removeEventListener("pointermove", track, true);
    window.removeEventListener("pointerdown", track, true);
    window.removeEventListener("mousedown", keepFocus, true);
    void unsubscribe.then((stop) => stop());
    react.unmount();
  };
}

const root = document.getElementById("root");
const client = createPageClient();
if (root && client && document.documentElement.dataset.cmuxPage === "omnibox-popup") {
  mountOmniboxPopupPage(root, client);
}
