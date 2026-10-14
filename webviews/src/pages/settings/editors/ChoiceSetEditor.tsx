import { useStore } from "../context";
import { text } from "../strings";
import { Switch } from "./ToggleEditor";
import type { EditorProps } from "./types";

/**
 * Any subset of fixed choices (`browser.toolbarButtons`): one switch per choice, in the schema's
 * order. A missing key shows the default; a switch writes the whole list back in choice order.
 */
export function ChoiceSetEditor({ row, value, disabled, labelId }: EditorProps) {
  const store = useStore();
  const choices = row.choices ?? [];
  const selected = choiceSetValues(
    choices.map((choice) => choice.value),
    value === undefined || value === null ? row.default : value,
  );
  const toggle = (choice: string, on: boolean) => {
    const next = choices.map((item) => item.value).filter((item) => (item === choice ? on : selected.includes(item)));
    void store.set(row.key, next);
  };
  return (
    <span className="folder-list" data-choice-set="" aria-labelledby={labelId}>
      {choices.map((choice) => {
        const id = `${labelId}-${choice.value}`;
        return (
          <span key={choice.value} className="folder-item" data-choice={choice.value}>
            <span className="folder-path" id={id}>
              {text(choice.title)}
            </span>
            <Switch
              checked={selected.includes(choice.value)}
              disabled={disabled}
              labelId={id}
              onToggle={(next) => toggle(choice.value, next)}
            />
          </span>
        );
      })}
    </span>
  );
}

/** The stored values that are choices, in the choices' order. */
export function choiceSetValues(choices: string[], value: unknown): string[] {
  const stored = Array.isArray(value) ? value.filter((item): item is string => typeof item === "string") : [];
  return choices.filter((choice) => stored.includes(choice));
}
