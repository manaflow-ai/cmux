import {
  useNativePopup,
  type NativePopupDescription,
  type NativePopupEvent,
  type NativePopupRow,
} from "../../ui/nativePopup";

export type ComposerPopupModel = NativePopupDescription;

/** Composer menus are native-only: the web surface supplies rows and consumes typed events. */
export function useComposerPopup({
  open,
  model,
  anchor,
  onEvent,
  onDismiss,
}: {
  open: boolean;
  model: ComposerPopupModel;
  anchor: () => HTMLElement | null;
  onEvent(event: NativePopupEvent): void;
  onDismiss(): void;
}): { available: boolean } {
  return useNativePopup({ open, model, anchor, onEvent, onDismiss });
}

export function popupChoice(
  id: string,
  label: string,
  options?: Partial<NativePopupRow>,
): NativePopupRow {
  return { id, kind: "choice", label, ...options };
}

export function popupAction(
  id: string,
  label: string,
  options?: Partial<NativePopupRow>,
): NativePopupRow {
  return { id, kind: "action", label, ...options };
}

export function popupSection(
  id: string,
  label: string,
  children: NativePopupRow[],
): NativePopupRow {
  return { id, kind: "section", label, children };
}

export function popupSeparator(id: string): NativePopupRow {
  return { id, kind: "separator", label: "" };
}

export function popupEventId(event: NativePopupEvent): string | undefined {
  return event.id;
}
