import { useRef, useState } from "react";
import { Combobox } from "../../../ui/Combobox";
import { Popover } from "../../../ui/Popover";
import { useSettingsState, useStore } from "../context";
import { Icon } from "../icons";
import { t, text } from "../strings";
import { TextEditor } from "./TextEditor";
import type { EditorProps } from "./types";

/** Published font/theme domains use the shared, portaled keyboard picker. */
export function DomainListEditor({ row, value, disabled, labelId }: EditorProps) {
  const store = useStore();
  const domains = useSettingsState().domains;
  const names = row.kind === "theme" ? domains.themes : domains.font_families;
  const [open, setOpen] = useState(false);
  const [filter, setFilter] = useState("");
  const anchor = useRef<HTMLButtonElement>(null);
  if (names.length === 0) return <TextEditor row={row} value={value} disabled={disabled} labelId={labelId} />;
  const current = typeof value === "string" ? value : null;
  const font = (name: string) => (row.kind === "font_family" ? { fontFamily: `"${name}", monospace` } : undefined);
  const shown = names.filter((name) => name.toLowerCase().includes(filter.trim().toLowerCase()));
  const close = () => {
    setOpen(false);
    setFilter("");
  };
  return (
    <span className="domain">
      <button
        ref={anchor}
        type="button"
        className="button domain-button"
        aria-expanded={open}
        aria-haspopup="dialog"
        aria-labelledby={labelId}
        disabled={disabled}
        style={current ? font(current) : undefined}
        onClick={() => (open ? close() : setOpen(true))}
      >
        {current === null || current === row.default ? text(row.default_label) || current : current}
        <Icon name="chevron" />
      </button>
      <Popover
        open={open && !disabled}
        onOpenChange={(next) => (next ? setOpen(true) : close())}
        anchor={anchor.current}
        finalFocus={anchor}
        label={text(row.title)}
        className="domain-panel bg-menu shadow-menu"
      >
        <Combobox
          inline
          suggestions={shown}
          onQuery={setFilter}
          onCancel={close}
          label={t("settingsPage.filter")}
          placeholder={t("settingsPage.filter")}
          inputClassName="field"
          listClassName="domain-list"
          itemClassName="domain-option"
          onSubmit={(name) => {
            if (!names.includes(name)) return;
            close();
            if (name !== current) void store.set(row.key, name);
          }}
          renderItem={(name) => (
            <span className="flex items-center justify-between gap-2" style={font(name)}>
              {name}
              {name === current && <Icon name="check" />}
            </span>
          )}
        />
        {shown.length === 0 && (
          <p className="empty text-muted" role="status">
            {t("settingsPage.pickerEmpty")}
          </p>
        )}
      </Popover>
    </span>
  );
}
