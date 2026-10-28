// A prewarmed spare page adopted by Cmd-T (plans/cmux-next/new-tab.md section 2.2). The spare
// loads, renders and connects before any tab exists; the host then dispatches the real context
// (AgentPaneView.adoptNewTab). WebKit runs that script before any key the user types after Cmd-T,
// so the remounted screen gets every key.
import { useEffect, useState } from "react";
import { flushSync } from "react-dom";
import { newTabHost, type NewTabHost } from "../NewTabPage";
import { omnibarContext } from "../omnibar";
import { parseWeather } from "./ambient";

export const NEW_TAB_ADOPT_EVENT = "acpmux-newtab-adopt";
/// The host's open tabs and workspaces changed while the page shows (AgentPaneView.refreshNewTabPlaces).
export const NEW_TAB_PLACES_EVENT = "acpmux-newtab-places";
/// The weather widget's reading arrived or changed while the page shows (AgentPaneView.refreshNewTabWeather).
export const NEW_TAB_WEATHER_EVENT = "acpmux-newtab-weather";

/// The context the host gave as the document committed (AgentPaneNavigation), for the first
/// render: the page draws New Tab with no round trip (cx-z9kz0). Undefined when it came too late
/// or the page is not a New Tab page; `useEarlyNewTabContext` asks then.
export function injectedNewTabContext(): NewTabHost | undefined {
  const injected = (window as { __cmuxNewTabContext?: unknown }).__cmuxNewTabContext;
  return injected === undefined ? undefined : newTabHost({ newTab: injected });
}

/// A cold New Tab page's context before the handshake (cx-0rpl.10): the host answers
/// `newTab.context` at once, while `ready` waits for acpmux, so the page draws its frame (layout,
/// field, empty list) at first render and the rows fill in after. Calls `onContext` once with the
/// context; `applied` turns true so the handshake keeps what the page did since (a left page stays
/// left). A page that rendered first with the injected context (`injectedNewTabContext`) does
/// not ask. `onSettled` runs once the host answered either way (or refused): the page then knows
/// whether it is a New Tab page.
export function useEarlyNewTabContext(
  callNative: (method: string) => Promise<unknown>,
  onContext: (host: NewTabHost) => void,
  onSettled?: () => void,
): { readonly current: boolean } {
  const [applied] = useState(() => ({ current: injectedNewTabContext() !== undefined }));
  useEffect(() => {
    if (applied.current) return;
    let cancelled = false;
    void callNative("newTab.context").then(
      (reply) => {
        const host = cancelled ? undefined : newTabHost({ newTab: (reply as { newTab?: unknown } | null)?.newTab });
        if (host && !applied.current) {
          applied.current = true;
          onContext(host);
        }
        if (!cancelled) onSettled?.();
      },
      () => {
        if (!cancelled) onSettled?.();
      },
    );
    return () => {
      cancelled = true;
    };
  }, [callNative, onContext, onSettled, applied]);
  return applied;
}

/// Calls `onAdopt` with each adopt event's context and returns the adoption count, a key that
/// remounts the screen so it starts from the new context.
export function useNewTabAdoption(onAdopt: (host: NewTabHost) => void): number {
  const [generation, setGeneration] = useState(0);
  useEffect(() => {
    const handle = (event: Event) => {
      const host = newTabHost({ newTab: (event as CustomEvent).detail });
      if (!host) return;
      // Render the adopted screen inside this event, before WebKit delivers the next key: a
      // render left for later would let typed keys land in the old field and be dropped.
      flushSync(() => {
        onAdopt(host);
        setGeneration((value) => value + 1);
      });
    };
    window.addEventListener(NEW_TAB_ADOPT_EVENT, handle);
    return () => window.removeEventListener(NEW_TAB_ADOPT_EVENT, handle);
  }, [onAdopt]);
  return generation;
}

/// Takes each places event's open tabs and workspaces into the shown page's bar, in place: no
/// remount, so what is typed and the caret stay (Leo 2026-10-11: rows for workspaces gone since
/// stayed listed).
export function useNewTabPlaces(
  update: (apply: (host: NewTabHost | undefined) => NewTabHost | undefined) => void,
): void {
  useEffect(() => {
    const handle = (event: Event) => {
      const places = omnibarContext((event as CustomEvent).detail);
      if (!places) return;
      update(
        (host) =>
          host && {
            ...host,
            omnibar: { ...(host.omnibar ?? places), tabs: places.tabs, workspaces: places.workspaces },
          },
      );
    };
    window.addEventListener(NEW_TAB_PLACES_EVENT, handle);
    return () => window.removeEventListener(NEW_TAB_PLACES_EVENT, handle);
  }, [update]);
}

/// Takes each weather event's reading into the shown page, in place (no remount): a page opened
/// before the first reading, or with an old one, shows the refreshed reading when it arrives. A
/// detail that is not a reading (null: the widget turned off) takes the reading away.
export function useNewTabWeather(
  update: (apply: (host: NewTabHost | undefined) => NewTabHost | undefined) => void,
): void {
  useEffect(() => {
    const handle = (event: Event) => {
      const weather = parseWeather((event as CustomEvent).detail);
      update((host) => {
        if (!host) return host;
        const { weather: _old, ...rest } = host;
        return weather ? { ...rest, weather } : rest;
      });
    };
    window.addEventListener(NEW_TAB_WEATHER_EVENT, handle);
    return () => window.removeEventListener(NEW_TAB_WEATHER_EVENT, handle);
  }, [update]);
}
