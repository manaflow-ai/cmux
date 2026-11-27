import { useState } from "react";
import { Button } from "../../../ui/Button";
import { Input } from "../../../ui/Input";
import { useStore } from "../context";
import { Icon } from "../icons";
import { t, text } from "../strings";
import { isHost } from "../validate";
import type { EditorProps } from "./types";

/** Host tokens: Return or comma adds, Backspace in an empty field removes the last one. A free-text
 * `string_list` (URL rules such as `re:^https://a,b`) takes any text and only Return adds. The empty
 * field shows the row's own placeholder; without one a host list shows its host example and a
 * free-text list shows none, so a list of words or rules never suggests a host. */
export function HostListEditor({ row, value, disabled, labelId }: EditorProps) {
  const store = useStore();
  const freeText = row.kind === "string_list";
  const placeholder = row.placeholder
    ? text(row.placeholder)
    : freeText
      ? undefined
      : t("settingsPage.hostPlaceholder");
  const hosts = Array.isArray(value) ? value.map(String) : [];
  const [draft, setDraft] = useState("");
  const [invalid, setInvalid] = useState(false);
  const write = (next: string[]) => void store.set(row.key, next);
  const add = () => {
    const host = freeText ? draft.trim() : draft.trim().replace(/,$/, "");
    if (host === "") return;
    if (!freeText && !isHost(host)) return setInvalid(true);
    setInvalid(false);
    setDraft("");
    if (!hosts.includes(host)) write([...hosts, host]);
  };
  return (
    <span className="host-list">
      <span className="tokens">
        {hosts.map((host) => (
          <span key={host} className="token">
            {host}
            <Button
              type="button"
              icon
              size="sm"
              variant="ghost"
              className="token-remove"
              aria-label={`${t("settingsPage.remove")} ${host}`}
              disabled={disabled}
              onClick={() => write(hosts.filter((item) => item !== host))}
            >
              <Icon name="xmark" />
            </Button>
          </span>
        ))}
        <Input
          className="field token-input"
          type="text"
          spellCheck={false}
          value={draft}
          placeholder={placeholder}
          disabled={disabled}
          aria-labelledby={labelId}
          aria-invalid={invalid}
          onChange={(event) => {
            const next = event.currentTarget.value;
            setDraft(next);
            if (invalid) setInvalid(false);
          }}
          onBlur={add}
          onKeyDown={(event) => {
            if (event.key === "Enter" || (event.key === "," && !freeText)) {
              event.preventDefault();
              add();
            } else if (event.key === "Backspace" && draft === "" && hosts.length > 0 && !event.metaKey) {
              write(hosts.slice(0, -1));
            }
          }}
        />
      </span>
      {invalid && (
        <span className="field-error" role="alert">
          {t("settingsPage.invalidHost")}
        </span>
      )}
    </span>
  );
}
