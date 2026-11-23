import { useState } from "react";
import { Button } from "../../../ui/Button";
import { Input } from "../../../ui/Input";
import { useStore } from "../context";
import { Icon } from "../icons";
import { t } from "../strings";
import type { EditorProps } from "./types";

type Actions = Record<string, Record<string, unknown>>;

/** The id a new command takes from its name: lowercase words joined by `-` (`Deploy Staging` is `deploy-staging`). */
export function actionId(name: string, taken: ReadonlySet<string>): string {
  const base =
    name
      .toLowerCase()
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-+|-+$/g, "") || "command";
  let id = base;
  for (let n = 2; taken.has(id); n += 1) id = `${base}-${n}`;
  return id;
}

/** What a command runs, for its line: its shell command, else the agent it starts. */
function runs(action: Record<string, unknown>): string {
  if (typeof action.command === "string" && action.command.trim() !== "") return action.command;
  return typeof action.agent === "string" ? action.agent : "";
}

/**
 * The `actions` row (cmux-next.json `actions.<id>`, ConfigActionParser): the person's own commands, which
 * the command palette lists as `cmuxConfig.<id>`. One line per command with its name, what it runs and
 * Remove; the last line adds one from a name and a shell command. Each change writes the whole object, as
 * cmux-next.json holds it, so the fields only the file sets (icon, tooltip, target, an agent) stay.
 */
export function ConfigActionsEditor({ row, value, disabled, labelId }: EditorProps) {
  const store = useStore();
  const actions: Actions =
    typeof value === "object" && value !== null && !Array.isArray(value)
      ? Object.fromEntries(
          Object.entries(value).filter(
            (entry): entry is [string, Record<string, unknown>] =>
              typeof entry[1] === "object" && entry[1] !== null && !Array.isArray(entry[1]),
          ),
        )
      : {};
  const [name, setName] = useState("");
  const [command, setCommand] = useState("");
  const write = (next: Actions) => void store.set(row.key, next);
  const add = () => {
    const title = name.trim();
    const shell = command.trim();
    if (title === "" || shell === "") return;
    setName("");
    setCommand("");
    write({ ...actions, [actionId(title, new Set(Object.keys(actions)))]: { title, command: shell } });
  };
  return (
    <span className="string-map" data-config-actions="">
      {Object.keys(actions)
        .sort()
        .map((id) => {
          const action = actions[id]!;
          const title = typeof action.title === "string" && action.title.trim() !== "" ? action.title : id;
          return (
            <span key={id} className="string-map-item" data-action-id={id}>
              <span className="string-map-key selectable">{title}</span>
              <span className="string-map-key selectable mono">{runs(action)}</span>
              <Button
                type="button"
                icon
                size="sm"
                variant="ghost"
                className="icon-button"
                aria-label={`${t("settingsPage.remove")} ${title}`}
                disabled={disabled}
                onClick={() => write(Object.fromEntries(Object.entries(actions).filter(([item]) => item !== id)))}
              >
                <Icon name="xmark" />
              </Button>
            </span>
          );
        })}
      {/* A form, so Return in either field adds as the Add button does. */}
      <form
        className="string-map-item"
        onSubmit={(event) => {
          event.preventDefault();
          add();
        }}
      >
        <Input
          className="field token-input"
          type="text"
          spellCheck={false}
          data-action-new-name=""
          value={name}
          placeholder={t("settingsPage.agents.name")}
          disabled={disabled}
          aria-labelledby={labelId}
          onChange={(event) => setName(event.currentTarget.value)}
        />
        <Input
          className="field text"
          type="text"
          spellCheck={false}
          data-action-new-command=""
          value={command}
          placeholder={t("settingsPage.agents.command")}
          disabled={disabled}
          aria-labelledby={labelId}
          onChange={(event) => setCommand(event.currentTarget.value)}
        />
        <Button
          type="submit"
          className="button"
          data-action-add=""
          disabled={disabled || name.trim() === "" || command.trim() === ""}
        >
          {t("settingsPage.add")}
        </Button>
      </form>
    </span>
  );
}
