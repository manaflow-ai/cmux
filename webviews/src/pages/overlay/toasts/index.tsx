// The overlay page's toast surface (route `/toasts`): the window's toasts as the app sends them
// (`cmux.overlay.toasts.state`), drawn by ToastStack, with the person's clicks and pointer and the
// toasts' places sent back (CmuxToastPageProvider.swift). main.tsx mounts it.
import { useEffect, useMemo, useState } from "react";
import { createRoot } from "react-dom/client";
import { createStrings } from "../../shared/i18n";
import type { PageClient } from "../../shared/pageClient";
import table from "./generated/strings.json";
import { ToastStack } from "./ToastStack";
import { readToastsState, TOASTS_OPS, TOASTS_STREAM, type ToastRect, type ToastsState } from "./types";

function ToastsSurface({ client }: { client: PageClient }) {
  const [state, setState] = useState<ToastsState>({ toasts: [], floor: 0 });
  const words = useMemo(() => createStrings(table), []);
  useEffect(() => {
    let stop: (() => void) | undefined;
    let ended = false;
    void client
      .subscribe<unknown>(TOASTS_STREAM, (data) => setState(readToastsState(data)))
      .then((unsubscribe) => {
        if (ended) unsubscribe();
        else stop = unsubscribe;
      });
    return () => {
      ended = true;
      stop?.();
    };
  }, [client]);
  // Fire and forget: a call the app refused (its window closed meanwhile) changes nothing here.
  const handlers = useMemo(() => {
    const send = (op: string, params: unknown) => void client.call(op, params).catch(() => undefined);
    return {
      onAction: (serial: number) => send(TOASTS_OPS.action, { serial }),
      onClose: (serial: number) => send(TOASTS_OPS.close, { serial }),
      onHover: (serial: number, hovered: boolean) => send(TOASTS_OPS.hover, { serial, hovered }),
      onLayout: (rects: ToastRect[], fading: ToastRect[]) => send(TOASTS_OPS.layout, { rects, fading }),
    };
  }, [client]);
  // The app draws each toast's glass under the page (CmuxToastPageView): the page cannot blur the window.
  return <ToastStack toasts={state.toasts} floor={state.floor} words={words} nativeGlass {...handlers} />;
}

/** Mounts the toast stack in `root`, talking to the app through `client`. */
export function mountToasts(root: HTMLElement, client: PageClient): void {
  createRoot(root).render(<ToastsSurface client={client} />);
}
