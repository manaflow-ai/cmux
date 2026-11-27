export interface ContextMenuPoint {
  x: number;
  y: number;
}

export type ContextMenuState =
  | { open: false }
  | { open: true; point: ContextMenuPoint };

export type ContextMenuAction =
  | { type: "open"; point: ContextMenuPoint }
  | { type: "close" };

export function contextMenuReducer(
  state: ContextMenuState,
  action: ContextMenuAction,
): ContextMenuState {
  if (action.type === "close") return { open: false };
  if (state.open && state.point.x === action.point.x && state.point.y === action.point.y) return state;
  return { open: true, point: action.point };
}
