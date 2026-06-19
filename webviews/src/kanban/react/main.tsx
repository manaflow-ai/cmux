import { useEffect, useReducer, useState } from "react";
import {
  cardsInColumn,
  KANBAN_COLUMNS,
  occupiesWipSlot,
  type KanbanCard,
  type KanbanColumn,
} from "../shared/types";
import { subscribeToKanbanEvents } from "../shared/bridge";
import {
  adjacentColumn,
  cancelCard,
  COLUMN_LABEL_KEYS,
  createTask,
  dispatchCard,
  initialState,
  loadInitialBoard,
  moveCard,
  reduceBoard,
  type KanbanCopy,
} from "../shared/boardModel";

/**
 * Root of the Kanban board surface. The native coordinator is authoritative:
 * this component reads the board through the bridge, renders columns, and asks
 * the native side to mutate; every reply / `boardUpdated` event replaces the
 * whole board in the reducer.
 */
export function KanbanApp() {
  const [state, dispatch] = useReducer(reduceBoard, initialState);
  const { board, copy, status, error, progress } = state;

  useEffect(() => {
    void loadInitialBoard(dispatch);
  }, []);
  useEffect(() => subscribeToKanbanEvents((event) => dispatch({ type: "event", event })), []);

  const [title, setTitle] = useState("");
  const [detail, setDetail] = useState("");

  const submit = async () => {
    const didCreate = await createTask(dispatch, copy, { title, detail });
    if (didCreate) {
      setTitle("");
      setDetail("");
    }
  };

  if (status === "loading" && !board) {
    return <div className="kanban-loading">{copy?.loading ?? "Loading board…"}</div>;
  }

  return (
    <section className="kanban-shell">
      <header className="kanban-toolbar">
        <span className="kanban-toolbar__title">{copy?.boardTitle ?? "Board"}</span>
        <form
          className="kanban-new-task"
          onSubmit={(event) => {
            event.preventDefault();
            void submit();
          }}
        >
          <input
            className="kanban-input kanban-input--title"
            value={title}
            placeholder={copy?.titlePlaceholder ?? "Task title"}
            aria-label={copy?.titlePlaceholder ?? "Task title"}
            onChange={(event) => setTitle(event.target.value)}
          />
          <input
            className="kanban-input kanban-input--detail"
            value={detail}
            placeholder={copy?.detailPlaceholder ?? "Details (optional)"}
            aria-label={copy?.detailPlaceholder ?? "Details"}
            onChange={(event) => setDetail(event.target.value)}
          />
          <button className="kanban-button" type="submit" disabled={title.trim().length === 0}>
            {copy?.addTask ?? "Add"}
          </button>
        </form>
      </header>
      {error ? <div className="kanban-error">{error}</div> : null}
      <div className="kanban-board">
        {KANBAN_COLUMNS.map((column) => (
          <KanbanColumnView
            key={column}
            column={column}
            copy={copy}
            cards={board ? cardsInColumn(board, column) : []}
            progress={progress}
            onMove={(cardId, target) => void moveCard(dispatch, copy, cardId, target)}
            onDispatch={(cardId) => void dispatchCard(dispatch, copy, cardId)}
            onCancel={(cardId) => void cancelCard(dispatch, copy, cardId)}
          />
        ))}
      </div>
    </section>
  );
}

function KanbanColumnView({
  column,
  cards,
  copy,
  progress,
  onMove,
  onDispatch,
  onCancel,
}: {
  column: KanbanColumn;
  cards: KanbanCard[];
  copy: KanbanCopy | null;
  progress: Record<string, string>;
  onMove: (cardId: string, target: KanbanColumn) => void;
  onDispatch: (cardId: string) => void;
  onCancel: (cardId: string) => void;
}) {
  const label = copy ? copy[COLUMN_LABEL_KEYS[column]] : column;
  return (
    <div className="kanban-column">
      <div className="kanban-column__header">
        <span>{label}</span>
        <span className="kanban-column__count">{cards.length}</span>
      </div>
      <div className="kanban-column__cards">
        {cards.length === 0 ? (
          <div className="kanban-column__empty">{copy?.emptyColumn ?? "No tasks"}</div>
        ) : (
          cards.map((card) => (
            <KanbanCardView
              key={card.id}
              card={card}
              copy={copy}
              progressLine={progress[card.id]}
              onMove={onMove}
              onDispatch={onDispatch}
              onCancel={onCancel}
            />
          ))
        )}
      </div>
    </div>
  );
}

function KanbanCardView({
  card,
  copy,
  progressLine,
  onMove,
  onDispatch,
  onCancel,
}: {
  card: KanbanCard;
  copy: KanbanCopy | null;
  progressLine: string | undefined;
  onMove: (cardId: string, target: KanbanColumn) => void;
  onDispatch: (cardId: string) => void;
  onCancel: (cardId: string) => void;
}) {
  const left = adjacentColumn(card.column, -1);
  const right = adjacentColumn(card.column, 1);
  const isRunning = occupiesWipSlot(card.column);
  const canDispatch = card.backendKind === "cmux" && (card.column === "backlog" || card.column === "ready");
  return (
    <div className="kanban-card">
      <div className="kanban-card__title">{card.title}</div>
      {card.detail.trim().length > 0 ? <div className="kanban-card__detail">{card.detail}</div> : null}
      {progressLine ? <div className="kanban-card__progress">{progressLine}</div> : null}
      <div className="kanban-card__footer">
        <div className="kanban-card__move">
          <button
            className="kanban-icon-button"
            type="button"
            disabled={!left}
            aria-label={copy?.moveLeft ?? "Move left"}
            onClick={() => {
              if (left) {
                onMove(card.id, left);
              }
            }}
          >
            ◀
          </button>
          <button
            className="kanban-icon-button"
            type="button"
            disabled={!right}
            aria-label={copy?.moveRight ?? "Move right"}
            onClick={() => {
              if (right) {
                onMove(card.id, right);
              }
            }}
          >
            ▶
          </button>
        </div>
        <div className="kanban-card__actions">
          {canDispatch ? (
            <button
              className="kanban-button kanban-button--dispatch"
              type="button"
              onClick={() => onDispatch(card.id)}
            >
              {copy?.dispatch ?? "Run"}
            </button>
          ) : null}
          {isRunning ? (
            <button
              className="kanban-button kanban-button--cancel"
              type="button"
              onClick={() => onCancel(card.id)}
            >
              {copy?.cancel ?? "Cancel"}
            </button>
          ) : null}
        </div>
      </div>
    </div>
  );
}
