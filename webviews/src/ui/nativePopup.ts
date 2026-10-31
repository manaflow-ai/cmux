import { useId, useLayoutEffect, useRef, useState } from "react";
import { usePopupHost } from "./UiProvider";
import type { AnchorBox } from "./popupHost";
import type { NativePopupEvent, NativePopupModel, NativePopupRow } from "./generated/popupProtocol";

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
  anchor: () => AnchorBox | null;
  onEvent(event: NativePopupEvent): void;
  onDismiss(reason?: string): void;
  /** The host could not show this opening (no window or web view): the consumer draws its web popup. */
  onUnavailable?(): void;
}

/**
 * The row a digit typed into an empty search field picks: the one whose shortcut it is, as the web
 * menus pick numbered rows on 1 to 9. Any other edit is search text.
 */
export function shortcutRowId(
  rows: readonly NativePopupRow[],
  previous: string,
  value: string | undefined,
): string | undefined {
  if (previous !== "" || value === undefined || !/^[1-9]$/.test(value)) return undefined;
  return rows.find((row) => row.kind === "action" && row.shortcut === value && row.disabled !== true)?.id;
}

/**
 * Native owns focus, keyboard, rendering and dismiss; callbacks only update domain state. `available`
 * turns false for the rest of an opening the host refused to show, so the consumer's web popup takes
 * over instead of the menu going missing.
 */
export function useNativePopup(options: NativePopupOptions): { available: boolean } {
  const host = usePopupHost()?.native;
  const [failed, setFailed] = useState(false);
  if (!options.open && failed) setFailed(false);
  const transport = failed ? undefined : host;
  const id = `popup-${useId()}`;
  const latest = useRef(options);
  latest.current = options;
  const revision = useRef(0);
  const opened = useRef(1);
  const shown = useRef(false);
  const serialized = JSON.stringify(options.model);

  useLayoutEffect(() => {
    if (!transport || !options.open) return;
    const revisionAtMount = revision;
    const stop = transport.listen((event) => {
      // An event belongs to this popup's displayed revision or an earlier one: an edit or pick made
      // while a newer revision is on its way still lands. Row IDs are stable keys, so a stale ID
      // either names the same row or none. Events of another popup or a later opening never do.
      if (event.popupId !== id || event.revision > revision.current || event.revision < opened.current) return;
      if (event.type === "dismiss") latest.current.onDismiss(event.reason);
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
      opened.current = model.revision;
      void transport.show(model).then((reply) => {
        if (!shown.current || model.revision < opened.current) return;
        if ((reply as { shown?: boolean } | undefined)?.shown === true) return;
        shown.current = false;
        setFailed(true);
        latest.current.onUnavailable?.();
      });
    }
  }, [transport, options.open, serialized, id]);

  return { available: transport !== undefined };
}
