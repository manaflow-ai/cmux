import { useId, useLayoutEffect, useRef } from "react";
import { usePopupHost } from "./UiProvider";
import type { NativePopupEvent, NativePopupModel } from "./generated/popupProtocol";

export type { NativePopupEvent, NativePopupModel, NativePopupRow } from "./generated/popupProtocol";

/** The generated model travels directly to AppKit; no mounted or hidden DOM rows. */
export interface NativePopupTransport {
  show(model: NativePopupModel): Promise<unknown>;
  update(model: NativePopupModel): void;
  hide(id: string, revision: number): void;
  listen(listener: (event: NativePopupEvent) => void): () => void;
}

export type NativePopupDescription = Omit<NativePopupModel, "schemaVersion" | "id" | "revision" | "anchor">;

export interface NativePopupOptions {
  open: boolean;
  model: NativePopupDescription;
  anchor: () => HTMLElement | null;
  onEvent(event: NativePopupEvent): void;
  onDismiss(): void;
}

/** Native owns focus, keyboard, rendering and dismiss; callbacks only update domain state. */
export function useNativePopup(options: NativePopupOptions): { available: boolean } {
  const transport = usePopupHost()?.native;
  const id = `popup-${useId()}`;
  const latest = useRef(options);
  latest.current = options;
  const revision = useRef(0);
  const shown = useRef(false);
  const serialized = JSON.stringify(options.model);

  useLayoutEffect(() => {
    if (!transport || !options.open) return;
    const revisionAtMount = revision;
    const stop = transport.listen((event) => {
      if (event.popupId !== id || event.revision !== revision.current) return;
      if (event.type === "dismiss") latest.current.onDismiss();
      else latest.current.onEvent(event);
    });
    return () => {
      stop();
      shown.current = false;
      transport.hide(id, revisionAtMount.current);
    };
  }, [transport, options.open, id]);

  useLayoutEffect(() => {
    if (!transport || !options.open) return;
    const anchor = latest.current.anchor();
    if (!anchor) return;
    const rect = anchor.getBoundingClientRect();
    const model: NativePopupModel = {
      ...latest.current.model,
      schemaVersion: 1,
      id,
      revision: ++revision.current,
      anchor: { left: rect.left, top: rect.top, right: rect.right, bottom: rect.bottom },
    };
    if (shown.current) transport.update(model);
    else {
      shown.current = true;
      void transport.show(model).then((reply) => {
        if (model.revision !== revision.current || !shown.current) return;
        if ((reply as { shown?: boolean } | undefined)?.shown !== true) latest.current.onDismiss();
      });
    }
  }, [transport, options.open, serialized, id]);

  return { available: transport !== undefined };
}
