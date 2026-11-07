// The toast stack's wire (CmuxToastPageProvider.swift): one stream from the app, four calls back.

/** One toast's action button: Undo, Reopen, a custom one, or Details (shows the toast in full). */
export interface ToastAction {
  title: string;
  /** Cmd-Z runs it while it is the window's newest undo toast (`showsUndoKey`). */
  isUndo: boolean;
  /** The button shows or hides the whole message and its detail in the toast; it never ends it. */
  revealsDetails: boolean;
}

/** One toast the window shows (`cmux.overlay.toasts.state`). */
export interface ToastState {
  /** Unique per show: a toast shown again under the same id has a new serial. */
  serial: number;
  /** A newer toast with the same id replaces this one. */
  id: string;
  message: string;
  detail?: string;
  action?: ToastAction;
  closable: boolean;
  /** Details is on: no line limit on the message, and the detail shows under it. */
  showsDetails: boolean;
  /** This toast's Undo is the one Cmd-Z runs. */
  showsUndoKey: boolean;
}

/** The window's toasts, oldest first, and the lowest bottom edge the stack may take, in CSS px from
 * the page's bottom (above the window's bottom, and above the message box it must never cover). */
export interface ToastsState {
  toasts: ToastState[];
  floor: number;
}

/** A toast's place in the page, CSS px from its top left (`cmux.overlay.toasts.layout`). */
export interface ToastRect {
  serial: number;
  x: number;
  y: number;
  w: number;
  h: number;
}

export const TOASTS_STREAM = "cmux.overlay.toasts.state";
export const TOASTS_OPS = {
  action: "cmux.overlay.toasts.action",
  close: "cmux.overlay.toasts.close",
  hover: "cmux.overlay.toasts.hover",
  layout: "cmux.overlay.toasts.layout",
} as const;

/** The state the stream sends, read defensively: anything malformed is dropped, never thrown. */
export function readToastsState(data: unknown): ToastsState {
  const value = (data ?? {}) as { toasts?: unknown; floor?: unknown };
  const floor = typeof value.floor === "number" && Number.isFinite(value.floor) ? Math.max(0, value.floor) : 0;
  const toasts: ToastState[] = [];
  for (const item of Array.isArray(value.toasts) ? value.toasts : []) {
    if (typeof item !== "object" || item === null) continue;
    const toast = item as Partial<ToastState> & { action?: Partial<ToastAction> };
    if (typeof toast.serial !== "number" || typeof toast.id !== "string" || typeof toast.message !== "string") continue;
    const action =
      toast.action && typeof toast.action.title === "string"
        ? {
            title: toast.action.title,
            isUndo: toast.action.isUndo === true,
            revealsDetails: toast.action.revealsDetails === true,
          }
        : undefined;
    toasts.push({
      serial: toast.serial,
      id: toast.id,
      message: toast.message,
      detail: typeof toast.detail === "string" && toast.detail.length > 0 ? toast.detail : undefined,
      action,
      closable: toast.closable !== false,
      showsDetails: toast.showsDetails === true && action?.revealsDetails === true,
      showsUndoKey: toast.showsUndoKey === true && action?.isUndo === true,
    });
  }
  // The stack shows at most three (CmuxToastStack.limit); a longer list keeps its newest.
  return { toasts: toasts.slice(-3), floor };
}
