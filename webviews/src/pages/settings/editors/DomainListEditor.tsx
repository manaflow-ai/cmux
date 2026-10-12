import { useState } from "react";
import { Popover } from "../../../ui/Popover";
import { useSettingsState, useStore } from "../context";
import { Icon } from "../icons";
import { t, text } from "../strings";
import { TextEditor } from "./TextEditor";
import type { EditorProps } from "./types";

/**
 * theme and font_family: a searchable list of the names the app published in ready().domains.
 * Font names render in their own face as the sample. With no published names, a text field.
 * The list is a pop-up over the rows, so opening it pushes no row down (cx-jh7kq).
 */
export function DomainListEditor({ row, value, disabled, labelId }: EditorProps) {
  const store = useStore();
  const domains = useSettingsState().domains;
  const names = row.kind === "theme" ? domains.themes : domains.font_families;
  const [open, setOpen] = useState(false);
  const [filter, setFilter] = useState("");
  const [button, setButton] = useState<HTMLButtonElement | null>(null);
  if (names.length === 0) return <TextEditor row={row} value={value} disabled={disabled} labelId={labelId} />;
  const current = typeof value === "string" ? value : null;
  const font = (name: string) => (row.kind === "font_family" ? { fontFamily: `"${name}", monospace` } : undefined);
  const shown = names.filter((name) => name.toLowerCase().includes(filter.trim().toLowerCase()));
  return (
    <span className="domain">
      <button
        ref={setButton}
        type="button"
        className="button domain-button"
        aria-expanded={open}
        aria-labelledby={labelId}
        disabled={disabled}
        style={current ? font(current) : undefined}
        onClick={() => setOpen(!open)}
      >
        {current === null || current === row.default ? text(row.default_label) || current : current}
        <Icon name="chevron" />
      </button>
      <Popover
        open={open && !disabled}
        onOpenChange={setOpen}
        anchor={button}
        label={text(row.title)}
        className="domain-panel"
      >
        <input
          className="field"
          type="search"
          value={filter}
          placeholder={t("settingsPage.filter")}
          aria-label={t("settingsPage.filter")}
          onChange={(event) => setFilter(event.currentTarget.value)}
        />
        <span className="domain-list">
          {shown.map((name) => (
            <button
              key={name}
              type="button"
              className="domain-option"
              aria-pressed={name === current}
              style={font(name)}
              onClick={() => {
                setOpen(false);
                if (name !== current) void store.set(row.key, name);
              }}
            >
              {name}
            </button>
          ))}
        </span>
      </Popover>
    </span>
  );
}
