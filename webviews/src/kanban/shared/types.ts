// Mirrors the Swift Kanban models in the `CmuxKanbanCore` package
// (`Packages/macOS/CmuxKanbanCore/Sources/CmuxKanbanCore/`).
//
// The native side persists a `KanbanBoard` as JSON (`JSONEncoder` with the
// `.iso8601` date strategy) and ships it across the bridge verbatim. Swift's
// synthesized `Codable` uses `encodeIfPresent` for optionals, so a `nil`
// property is *omitted* from the JSON rather than serialized as `null` — every
// optional below is therefore declared with `?` (possibly `undefined`), never
// `| null`.

/** A column in the board's task pipeline. Mirrors Swift `KanbanColumn`. */
export type KanbanColumn =
  | "backlog"
  | "ready"
  | "building"
  | "testing"
  | "done"
  | "blocked"
  | "failed";

/** Ordered pipeline columns, left-to-right, for rendering the board. */
export const KANBAN_COLUMNS: readonly KanbanColumn[] = [
  "backlog",
  "ready",
  "building",
  "testing",
  "done",
  "blocked",
  "failed",
];

/** The dispatch backend that executes a card's task. Mirrors `KanbanBackendKind`. */
export type KanbanBackendKind = "cmux" | "cnvs" | "hermes";

/** Native agent provider used when `backendKind` is `"cmux"`. The core stores
 * this as the provider's raw string; these are the values the app validates. */
export type KanbanAgentProvider = "codex" | "claude" | "opencode";

/** A single task on the board. Mirrors Swift `KanbanCard`. */
export interface KanbanCard {
  id: string;
  title: string;
  detail: string;
  column: KanbanColumn;
  backendKind: KanbanBackendKind;
  /** Present only for the `"cmux"` backend; external backends use `agentLabel`. */
  agentProvider?: KanbanAgentProvider;
  agentLabel?: string;
  sessionId?: string;
  worktreePath?: string;
  branchName?: string;
  logsRef?: string;
  lastExitStatus?: number;
  /** ISO-8601 timestamp. */
  createdAt: string;
  /** ISO-8601 timestamp. */
  updatedAt: string;
}

/** The persisted board for one workspace. Mirrors Swift `KanbanBoard`. */
export interface KanbanBoard {
  schemaVersion: number;
  workspaceId: string;
  wipLimit: number;
  ripping: boolean;
  testCommand?: string;
  defaultBackend: KanbanBackendKind;
  defaultProvider: KanbanAgentProvider;
  cards: KanbanCard[];
  /** ISO-8601 timestamp. */
  updatedAt: string;
}

/** Columns whose cards occupy a WIP slot. Mirrors `KanbanColumn.occupiesWipSlot`. */
export function occupiesWipSlot(column: KanbanColumn): boolean {
  return column === "building" || column === "testing";
}

/** Cards in a column, preserving board order. */
export function cardsInColumn(board: KanbanBoard, column: KanbanColumn): KanbanCard[] {
  return board.cards.filter((card) => card.column === column);
}

/** Number of cards currently occupying a WIP slot. Mirrors `KanbanBoard.wipInUse`. */
export function wipInUse(board: KanbanBoard): number {
  return board.cards.reduce((count, card) => (occupiesWipSlot(card.column) ? count + 1 : count), 0);
}
