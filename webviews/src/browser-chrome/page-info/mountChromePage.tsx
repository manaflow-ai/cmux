// Boots one of the browser chrome's React pages (Page Info's bubble and windows) over CmuxNextPages'
// BrowserChromeWebHost: the host pushes the page's state on `cmux.<page>.state`; the page sends
// each command on `cmux.<page>.command` and the height its content needs on `cmux.<page>.size`,
// which sizes the native panel or window around it.
import { useLayoutEffect, useSyncExternalStore, type ReactNode } from "react";
import { createRoot } from "react-dom/client";
import type { PageClient } from "../../pages/shared/pageClient";
import { setDocumentLanguage, type Strings } from "../../pages/shared/i18n";
import { UiProvider, languageDirection } from "../../ui/UiProvider";
import { pageInfoStrings } from "./strings";

export type ChromePageOptions<State, Command> = {
  /** The page id after `cmux.` (`page-info`, `site-settings`, ...). */
  page: string;
  render: (state: State, send: (command: Command) => void, strings: Strings) => ReactNode;
  /** Runs on each state before it renders (the bubble's density metrics). */
  onState?: (state: State) => void;
  /** The element that keeps the keys while the page shows. */
  focus?: string;
};

/** A state the host numbered: a size report names the push it measured. */
type Numbered = { revision?: number };

export function mountChromePage<State, Command>(
  root: HTMLElement,
  client: PageClient,
  { page, render, onState, focus }: ChromePageOptions<State, Command>,
): () => void {
  let state: State | null = null;
  const listeners = new Set<() => void>();
  const store = {
    subscribe: (listener: () => void) => {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    get: () => state,
  };
  const unsubscribe = client.subscribe<State>(`cmux.${page}.state`, (next) => {
    onState?.(next);
    state = next;
    for (const listener of listeners) listener();
  });
  const send = (command: Command) => void client.call(`cmux.${page}.command`, command);
  // The host sizes its panel or window from the height of each state it pushed (a reopen with
  // the same height too), and resizes it when the content changes height by itself.
  const report = () => {
    const height = Math.ceil(root.getBoundingClientRect().height);
    if (height > 0 && state) {
      void client.call(`cmux.${page}.size`, { height, revision: (state as Numbered).revision });
    }
  };
  const sizes = new ResizeObserver(report);
  sizes.observe(root);

  const strings = pageInfoStrings();
  setDocumentLanguage(strings.language);
  function Page() {
    const current = useSyncExternalStore(store.subscribe, store.get);
    // After each committed state: report its height, and keep the keys in the page.
    useLayoutEffect(() => {
      if (!current) return;
      report();
      const target = focus ? root.querySelector<HTMLElement>(focus) : null;
      if (target && !target.contains(document.activeElement)) target.focus();
    }, [current]);
    return current ? render(current, send, strings) : null;
  }
  const react = createRoot(root);
  react.render(
    <UiProvider container={root} dir={languageDirection(strings.language)}>
      <Page />
    </UiProvider>,
  );
  return () => {
    sizes.disconnect();
    void unsubscribe.then((stop) => stop());
    react.unmount();
  };
}
