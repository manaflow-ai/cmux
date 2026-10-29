import { useId, useLayoutEffect, useRef } from "react";
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
}

/** Native owns focus, keyboard, rendering and dismiss; callbacks only update domain state. */
export function useNativePopup(options: NativePopupOptions): { available: boolean } {
  const transport = usePopupHost()?.native;
  const id = `popup-${useId()}`;
  const latest = useRef(options);
  latest.current = options;
  const revision = useRef(0);
  const openingRevision = useRef(0);
  const shown = useRef(false);
  const editSequences = useRef(new Map<string, number>());
  const serialized = JSON.stringify(options.model);

  useLayoutEffect(() => {
    if (!transport || !options.open) return;
    const revisionAtMount = revision;
    const stop = transport.listen((event) => {
      if (event.popupId !== id) return;
      if (event.type === "dismiss") {
        if (event.revision < openingRevision.current || event.revision > revision.current) return;
        latest.current.onDismiss(event.reason);
      } else {
        if (event.revision < openingRevision.current || event.revision > revision.current) return;
        if (event.editSequence !== undefined) {
          const prior = editSequences.current.get(event.id ?? "") ?? -1;
          if (event.editSequence <= prior) return;
          editSequences.current.set(event.id ?? "", event.editSequence);
        }
        latest.current.onEvent(event);
      }
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
    if (!shown.current) editSequences.current.clear();
    const rect = anchor.getBoundingClientRect();
    const model: NativePopupModel = {
      ...withEditSequences(latest.current.model, editSequences.current),
      schemaVersion: 1,
      id,
      revision: ++revision.current,
      anchor: { left: rect.left, top: rect.top, right: rect.right, bottom: rect.bottom },
    };
    if (shown.current) transport.update(model);
    else {
      shown.current = true;
      openingRevision.current = model.revision;
      void transport.show(model).then((reply) => {
        if (openingRevision.current !== model.revision || !shown.current) return;
        if ((reply as { shown?: boolean } | undefined)?.shown !== true) latest.current.onDismiss();
      });
    }
  }, [transport, options.open, serialized, id]);

  return { available: transport !== undefined };
}

function withEditSequences(model: NativePopupDescription, sequences: Map<string, number>): NativePopupDescription {
  const rows = (items: NativePopupRow[]): NativePopupRow[] => items.map((row) => ({
    ...row,
    ...(row.kind === "textField" && sequences.has(row.id) ? { editSequence: sequences.get(row.id) } : {}),
    ...(row.children ? { children: rows(row.children) } : {}),
  }));
  return {
    ...model,
    ...(model.search && sequences.has(model.search.id)
      ? { search: { ...model.search, editSequence: sequences.get(model.search.id) } }
      : {}),
    rows: rows(model.rows),
    ...(model.rail ? { rail: rows(model.rail) } : {}),
    ...(model.footer ? { footer: rows(model.footer) } : {}),
  };
}
