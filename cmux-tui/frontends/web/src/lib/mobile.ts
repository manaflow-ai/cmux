export type DrawerState = "open" | "closed";
export type DrawerAction = "open" | "close" | "toggle" | "select";

export function drawerReducer(state: DrawerState, action: DrawerAction): DrawerState {
  if (action === "toggle") return state === "open" ? "closed" : "open";
  if (action === "open") return "open";
  return "closed";
}

export function encodeCtrlKey(key: string): string | null {
  if (!/^[a-z]$/i.test(key)) return null;
  return String.fromCharCode(key.toUpperCase().charCodeAt(0) - 64);
}

