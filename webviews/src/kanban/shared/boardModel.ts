import type { KanbanBoard, KanbanColumn } from "./types";
import { KANBAN_COLUMNS } from "./types";
import { callNativeKanban, type KanbanEvent } from "./bridge";

/**
 * Localized UI copy shipped from Swift via `app.context`. Mirrors the keys
 * emitted by `KanbanWebRendererCoordinator.boardCopy()` so all user-facing text
 * stays in the native localization catalog.
 */
export type KanbanCopy = {
  boardTitle: string;
  columnBacklog: string;
  columnReady: string;
  columnBuilding: string;
  columnTesting: string;
  columnDone: string;
  columnBlocked: string;
  columnFailed: string;
  newTask: string;
  addTask: string;
  titlePlaceholder: string;
  detailPlaceholder: string;
  moveLeft: string;
  moveRight: string;
  emptyColumn: string;
  loading: string;
  requestFailed: string;
};

export type KanbanStatus = "loading" | "ready" | "error";

export type KanbanState = {
  status: KanbanStatus;
  board: KanbanBoard | null;
  copy: KanbanCopy | null;
  error: string | null;
};

export type KanbanAction =
  | { type: "contextLoaded"; copy: KanbanCopy }
  | { type: "boardLoaded"; board: KanbanBoard }
  | { type: "event"; event: KanbanEvent }
  | { type: "error"; message: string };

export const initialState: KanbanState = {
  status: "loading",
  board: null,
  copy: null,
  error: null,
};

/** Pure board reducer. Board mutations are server-authoritative: every native
 * reply / `boardUpdated` event replaces the whole board. */
export function reduceBoard(state: KanbanState, action: KanbanAction): KanbanState {
  switch (action.type) {
    case "contextLoaded":
      return { ...state, copy: action.copy };
    case "boardLoaded":
      return { ...state, status: "ready", board: action.board, error: null };
    case "event":
      if (action.event.type === "kanban.boardUpdated") {
        return { ...state, status: "ready", board: action.event.board, error: null };
      }
      return state;
    case "error":
      return { ...state, status: state.board ? state.status : "error", error: action.message };
  }
}

export const COLUMN_LABEL_KEYS: Record<KanbanColumn, keyof KanbanCopy> = {
  backlog: "columnBacklog",
  ready: "columnReady",
  building: "columnBuilding",
  testing: "columnTesting",
  done: "columnDone",
  blocked: "columnBlocked",
  failed: "columnFailed",
};

/** The column immediately left/right of `column` in pipeline order, or null at
 * the ends. Used by the per-card move controls (Phase 2 has no drag-and-drop). */
export function adjacentColumn(column: KanbanColumn, direction: -1 | 1): KanbanColumn | null {
  const index = KANBAN_COLUMNS.indexOf(column);
  const next = index + direction;
  if (index < 0 || next < 0 || next >= KANBAN_COLUMNS.length) {
    return null;
  }
  return KANBAN_COLUMNS[next] ?? null;
}

function messageForError(error: unknown, copy: KanbanCopy | null): string {
  if (error instanceof Error && error.message) {
    return error.message;
  }
  return copy?.requestFailed ?? "Board request failed.";
}

type Dispatch = (action: KanbanAction) => void;

export async function loadInitialBoard(dispatch: Dispatch): Promise<void> {
  try {
    const context = await callNativeKanban<{ copy: KanbanCopy }>("app.context");
    dispatch({ type: "contextLoaded", copy: context.copy });
    const board = await callNativeKanban<KanbanBoard>("getBoard");
    dispatch({ type: "boardLoaded", board });
  } catch (error) {
    dispatch({ type: "error", message: messageForError(error, null) });
  }
}

export async function createTask(
  dispatch: Dispatch,
  copy: KanbanCopy | null,
  input: { title: string; detail?: string },
): Promise<boolean> {
  const title = input.title.trim();
  if (title.length === 0) {
    return false;
  }
  try {
    const board = await callNativeKanban<KanbanBoard>("createTask", {
      title,
      detail: input.detail ?? "",
    });
    dispatch({ type: "boardLoaded", board });
    return true;
  } catch (error) {
    dispatch({ type: "error", message: messageForError(error, copy) });
    return false;
  }
}

export async function moveCard(
  dispatch: Dispatch,
  copy: KanbanCopy | null,
  cardId: string,
  column: KanbanColumn,
): Promise<void> {
  try {
    const board = await callNativeKanban<KanbanBoard>("moveCard", { cardId, column });
    dispatch({ type: "boardLoaded", board });
  } catch (error) {
    dispatch({ type: "error", message: messageForError(error, copy) });
  }
}
