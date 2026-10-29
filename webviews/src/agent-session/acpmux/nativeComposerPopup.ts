import { popupAction as resolvePopupAction, selectDescription } from "../../ui/popupDescriptors";
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
  onDismiss(reason?: string): void;
}): { available: boolean } {
  return useNativePopup({
    open,
    model,
    anchor,
    onDismiss,
    onEvent(event) {
      const action = event.type === "pick" ? resolvePopupAction(model, event.id) : undefined;
      if (event.type === "pick" && !action) return;
      onEvent(event);
      // The host hides terminal picks without emitting a second dismiss event.
      if (action && !action.keepOpen) onDismiss("pick");
    },
  });
}

export function popupChoice(id: string, label: string, options?: Partial<NativePopupRow>): NativePopupRow {
  return { id, kind: "action", label, ...options };
}

export function popupAction(id: string, label: string, options?: Partial<NativePopupRow>): NativePopupRow {
  return { id, kind: "action", label, ...options };
}

export function popupSection(id: string, label: string, children: NativePopupRow[]): NativePopupRow[] {
  return [...(label ? [{ id, kind: "section" as const, label }] : []), ...children];
}

export function popupSeparator(id: string): NativePopupRow {
  return { id, kind: "separator", label: "" };
}

export function popupEventId(event: NativePopupEvent): string | undefined {
  return event.id;
}

/** Keep native control identity stable across live reordering without embedding domain strings. */
export function popupIdentity(...parts: string[]): string {
  const value = JSON.stringify(parts);
  return selectDescription({ options: [{ value, label: "" }], value }).rows[0]!.id;
}
