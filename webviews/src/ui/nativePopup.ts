import { useId, useLayoutEffect, useReducer, useRef } from "react";
import { usePopupHost } from "./UiProvider";
import type { AnchorBox } from "./popupHost";
import type { NativePopupEvent, NativePopupModel, NativePopupRow } from "./generated/popupProtocol";
import { NativePopupEventFence } from "./nativePopupEvents";

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
  const eventFence = useRef(new NativePopupEventFence());
  const [acknowledgment, acknowledge] = useReducer((value: number) => value + 1, 0);
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
        if (!eventFence.current.accepts(event)) return;
        if (event.editSequence !== undefined) {
          if (!event.id || !Number.isSafeInteger(event.editSequence) || event.editSequence < 0) return;
          const prior = editSequences.current.get(event.id ?? "") ?? -1;
          if (event.editSequence <= prior) return;
          editSequences.current.set(event.id ?? "", event.editSequence);
          acknowledge();
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
    if (!shown.current) {
      editSequences.current.clear();
      eventFence.current.reset();
    }
    const rect = anchor.getBoundingClientRect();
    const model: NativePopupModel = {
      ...withEditSequences(latest.current.model, editSequences.current),
      schemaVersion: 1,
      id,
      revision: ++revision.current,
      anchor: { left: rect.left, top: rect.top, right: rect.right, bottom: rect.bottom },
    };
    eventFence.current.update(model);
    if (shown.current) transport.update(model);
    else {
      shown.current = true;
      openingRevision.current = model.revision;
      void transport.show(model).then((reply) => {
        if (openingRevision.current !== model.revision || !shown.current) return;
        if ((reply as { shown?: boolean } | undefined)?.shown !== true) latest.current.onDismiss();
      });
    }
  }, [transport, options.open, serialized, acknowledgment, id]);

  return { available: transport !== undefined };
}

function withEditSequences(model: NativePopupDescription, sequences: Map<string, number>): NativePopupDescription {
  const liveFields = new Set(model.search ? [model.search.id] : []);
  const collect = (items: NativePopupRow[]) => {
    for (const row of items) {
      if (row.kind === "textField") liveFields.add(row.id);
      if (row.children) collect(row.children);
    }
  };
  collect([...(model.rail ?? []), ...model.rows, ...(model.footer ?? [])]);
  for (const id of sequences.keys()) if (!liveFields.has(id)) sequences.delete(id);
  const rows = (items: NativePopupRow[]): NativePopupRow[] =>
    items.map((row) => ({
      ...row,
      ...(row.kind === "textField" ? { editSequence: sequences.get(row.id) ?? 0 } : {}),
      ...(row.children ? { children: rows(row.children) } : {}),
    }));
  return {
    ...model,
    ...(model.search ? { search: { ...model.search, editSequence: sequences.get(model.search.id) ?? 0 } } : {}),
    rows: rows(model.rows),
    ...(model.rail ? { rail: rows(model.rail) } : {}),
    ...(model.footer ? { footer: rows(model.footer) } : {}),
  };
}
