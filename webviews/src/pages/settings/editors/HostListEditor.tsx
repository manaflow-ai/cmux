import { useState } from "react";
import { useStore } from "../context";
import { Icon } from "../icons";
import { t } from "../strings";
import { isHost } from "../validate";
import type { EditorProps } from "./types";

/** Host tokens: Return or comma adds, Backspace in an empty field removes the last one. */
export function HostListEditor({ row, value, disabled, labelId }: EditorProps) {
  const store = useStore();
  const hosts = Array.isArray(value) ? value.map(String) : [];
  const [draft, setDraft] = useState("");
  const [invalid, setInvalid] = useState(false);
  const write = (next: string[]) => void store.set(row.key, next);
  const add = () => {
    const host = draft.trim().replace(/,$/, "");
    if (host === "") return;
    if (!isHost(host)) return setInvalid(true);
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
            <button
              type="button"
              className="token-remove"
              aria-label={`${t("settingsPage.remove")} ${host}`}
              disabled={disabled}
              onClick={() => write(hosts.filter((item) => item !== host))}
            >
              <Icon name="xmark" />
            </button>
          </span>
        ))}
        <input
          className="field token-input"
          type="text"
          spellCheck={false}
          value={draft}
          placeholder={t("settingsPage.hostPlaceholder")}
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
            if (event.key === "Enter" || event.key === ",") {
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
