import { useId, useLayoutEffect, useReducer, useRef } from "react";
import { usePopupHost } from "./UiProvider";
import type { AnchorBox } from "./popupHost";
import type { NativePopupEvent, NativePopupModel, NativePopupRow } from "./popupProtocol";
import { NativePopupEventFence } from "./nativePopupEvents";

export type { NativePopupEvent, NativePopupModel, NativePopupRow } from "./popupProtocol";

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
  const editSequences = useRef(new Map<string, { received: number; value: string | undefined; applied: number }>());
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
        // The native popup is gone: a later model change must show it again, not update it.
        shown.current = false;
        latest.current.onDismiss(event.reason);
      } else {
        if (event.revision < openingRevision.current || event.revision > revision.current) return;
        if (!eventFence.current.accepts(event)) return;
        if (event.editSequence !== undefined) {
          if (!event.id || !Number.isSafeInteger(event.editSequence) || event.editSequence < 0) return;
          const prior = editSequences.current.get(event.id);
          if (event.editSequence <= (prior?.received ?? -1)) return;
          editSequences.current.set(event.id, {
            received: event.editSequence,
            value: event.value,
            applied: prior?.applied ?? 0,
          });
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
    if (!anchor) {
      // A popup already on screen must not outlive its anchor at the old position.
      if (shown.current) {
        shown.current = false;
        transport.hide(id, revision.current);
        latest.current.onDismiss("anchor-gone");
      }
      return;
    }
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
        if ((reply as { shown?: boolean } | undefined)?.shown !== true) {
          shown.current = false;
          latest.current.onDismiss();
        }
      });
    }
  }, [transport, options.open, serialized, acknowledgment, id]);

  return { available: transport !== undefined };
}

function withEditSequences(
  model: NativePopupDescription,
  sequences: Map<string, { received: number; value: string | undefined; applied: number }>,
): NativePopupDescription {
  const liveFields = new Set(model.search ? [model.search.id] : []);
  const collect = (items: NativePopupRow[]) => {
    for (const row of items) {
      if (row.kind === "textField") liveFields.add(row.id);
      if (row.children) collect(row.children);
    }
  };
  collect([...(model.rail ?? []), ...model.rows, ...(model.footer ?? [])]);
  for (const id of sequences.keys()) if (!liveFields.has(id)) sequences.delete(id);
  const applied = (id: string, value: string | undefined, explicit: number | undefined): number => {
    const edit = sequences.get(id);
    if (!edit) return explicit ?? 0;
    // Receipt is not application: async consumers may still be rendering the old value.
    if (value === edit.value) edit.applied = Math.max(edit.applied, edit.received);
    if (explicit !== undefined) edit.applied = Math.max(edit.applied, explicit);
    return edit.applied;
  };
  const rows = (items: NativePopupRow[]): NativePopupRow[] =>
    items.map((row) => ({
      ...row,
      ...(row.kind === "textField" ? { editSequence: applied(row.id, row.value, row.editSequence) } : {}),
      ...(row.children ? { children: rows(row.children) } : {}),
    }));
  return {
    ...model,
    ...(model.search
      ? {
          search: {
            ...model.search,
            editSequence: applied(model.search.id, model.search.value, model.search.editSequence),
          },
        }
      : {}),
    rows: rows(model.rows),
    ...(model.rail ? { rail: rows(model.rail) } : {}),
    ...(model.footer ? { footer: rows(model.footer) } : {}),
  };
}
