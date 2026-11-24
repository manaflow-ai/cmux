import { useRef, type DragEvent, type ReactNode } from "react";
import type { SceneDispatch } from "./SceneRenderer";
import type { SceneNode, SceneStore } from "./store";

/** One HTML drag stays inside its list. The app supplies the new order after the drop. */
export function SceneReorderable({
  node,
  store,
  dispatch,
  rows,
}: {
  node: SceneNode;
  store: SceneStore;
  dispatch: SceneDispatch;
  rows: { id: string; leaving?: boolean; content: ReactNode }[];
}) {
  const source = useRef<string | null>(null);
  const indicator = useRef<HTMLElement | null>(null);
  const clear = () => {
    if (indicator.current) delete indicator.current.dataset.dropEdge;
    indicator.current = null;
  };
  const finish = () => {
    clear();
    source.current = null;
  };

  function dropAt(event: DragEvent<HTMLDivElement>, target: string) {
    if (source.current === null) return null;
    const from = node.children.indexOf(source.current);
    const to = node.children.indexOf(target);
    if (from < 0 || to < 0) return null;
    event.preventDefault();
    event.stopPropagation();
    const rect = event.currentTarget.getBoundingClientRect();
    const after = event.clientY >= rect.top + rect.height / 2;
    if (from === to) return null;
    const index = to + Number(after) - Number(from < to);
    return index === from ? null : { index, edge: after ? "after" : "before" };
  }

  return rows.map(({ id, leaving, content }) => {
    const row = store.getNode(id);
    const draggable = !leaving && typeof row?.props.reorderKey === "string" && row.props.disabled !== true;
    return (
      <div
        key={id}
        className="cmux-app-scene-move-row"
        draggable={draggable}
        onDragStart={(event) => {
          if (
            !draggable ||
            store.getNode(id)?.props.disabled === true ||
            (event.target instanceof Element && event.target.closest("input,textarea,[contenteditable=true]"))
          ) {
            event.preventDefault();
            return;
          }
          event.stopPropagation();
          source.current = id;
          event.dataTransfer.effectAllowed = "move";
          event.dataTransfer.setData("application/x-cmux-scene-row", id);
        }}
        onDragOver={(event) => {
          const place = dropAt(event, id);
          clear();
          if (place) {
            indicator.current = event.currentTarget;
            event.currentTarget.dataset.dropEdge = place.edge;
            event.dataTransfer.dropEffect = "move";
          }
        }}
        onDragLeave={clear}
        onDragEnd={(event) => {
          event.stopPropagation();
          finish();
        }}
        onDrop={(event) => {
          const place = dropAt(event, id);
          const key = source.current === null ? null : store.getNode(source.current)?.props.reorderKey;
          finish();
          if (place && typeof key === "string") dispatch(node.id, "move", { id: key, index: place.index });
        }}
      >
        {content}
      </div>
    );
  });
}
