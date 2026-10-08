import { useStore } from "../context";
import { Icon } from "../icons";
import { t, text } from "../strings";
import type { EditorProps } from "./types";

/**
 * An order of fixed choices (`sidebar.workspaceRow.secondLineOrder`): every choice once, with
 * move up and move down. Choices the stored list leaves out follow in the schema's order, as the
 * app reads them, so the list always shows the order that applies.
 */
export function OrderedChoicesEditor({ row, value, disabled, labelId }: EditorProps) {
  const store = useStore();
  const order = orderedChoiceValues(row.choices?.map((choice) => choice.value) ?? [], value);
  const titles = new Map(row.choices?.map((choice) => [choice.value, text(choice.title)]) ?? []);
  const move = (index: number, by: number) => {
    const next = [...order];
    const [item] = next.splice(index, 1);
    next.splice(index + by, 0, item!);
    void store.set(row.key, next);
  };
  return (
    <span className="folder-list" data-ordered-choices="" aria-labelledby={labelId}>
      {order.map((choice, index) => (
        <span key={choice} className="folder-item" data-choice={choice}>
          <span className="folder-path">{titles.get(choice) ?? choice}</span>
          <button
            type="button"
            className="icon-button"
            aria-label={`${t("settingsPage.moveUp")} ${titles.get(choice) ?? choice}`}
            disabled={disabled || index === 0}
            onClick={() => move(index, -1)}
          >
            <Icon name="chevron" className="icon-up" />
          </button>
          <button
            type="button"
            className="icon-button"
            aria-label={`${t("settingsPage.moveDown")} ${titles.get(choice) ?? choice}`}
            disabled={disabled || index === order.length - 1}
            onClick={() => move(index, 1)}
          >
            <Icon name="chevron" />
          </button>
        </span>
      ))}
    </span>
  );
}

/** The stored values that are choices (first occurrence), then the choices it left out. */
export function orderedChoiceValues(choices: string[], value: unknown): string[] {
  const stored = Array.isArray(value) ? value.filter((item): item is string => typeof item === "string") : [];
  const listed = [...new Set(stored.filter((item) => choices.includes(item)))];
  return [...listed, ...choices.filter((choice) => !listed.includes(choice))];
}
