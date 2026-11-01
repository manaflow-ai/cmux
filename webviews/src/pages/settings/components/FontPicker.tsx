// A font family choice (terminal, chat code, editor, Markdown code): a button in the picked face and
// a popover to search the installed fixed-pitch families, each drawn in its own face. Recent fonts
// lead the list (fontPickerModel). It previews like the theme picker: the row the arrow keys
// highlight shows live in the app at once, a row the pointer rests on after DWELL_MS; Return or a
// click picks, Escape reverts. The popover floats over the rows, so opening it pushes no row down.
import { useEffect, useRef, useState } from "react";
import { Combobox } from "../../../ui/Combobox";
import { Popover } from "../../../ui/Popover";
import { Icon } from "../icons";
import { t } from "../strings";
import { DEFAULT_FONT_ROW, fontFace, fontRows } from "../fontPickerModel";
import { DWELL_MS } from "./ThemePicker";

export function FontPicker({
  value,
  names,
  recent,
  labelId,
  disabled,
  title,
  defaultLabel,
  onPick,
  onPreview,
}: {
  /** The picked family; null shows `defaultLabel`. */
  value: string | null;
  names: readonly string[];
  /** Fonts picked lately, newest first. */
  recent: readonly string[];
  labelId: string;
  disabled: boolean;
  /** The row's title, for the popover and its search field. */
  title: string;
  defaultLabel: string;
  /** Writes the choice (null resets); the live preview ends once the returned promise settles. */
  onPick(name: string | null): void | Promise<unknown>;
  /** The highlighted family while the list is open; null when it closes or rests on the default. */
  onPreview(name: string | null, owner?: object): void;
}) {
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");
  const [anchor, setAnchor] = useState<HTMLButtonElement | null>(null);
  // A press on the button while the list is open closes it as a press outside; the click that
  // follows must not open it again. Never closed yet: no guard, or a click in the page's first
  // 400 ms would do nothing.
  const closedAt = useRef(Number.NEGATIVE_INFINITY);
  const showing = useRef<string | null>(null);
  const owner = useRef<object | null>(null);
  const dwell = useRef<ReturnType<typeof setTimeout> | null>(null);
  const cancelDwell = () => {
    if (dwell.current !== null) clearTimeout(dwell.current);
    dwell.current = null;
  };
  const preview = (name: string | null) => {
    cancelDwell();
    if (name === showing.current) return;
    // No preview left to show: end the one in effect under its own owner.
    if (name === null) return end();
    showing.current = name;
    owner.current = {};
    onPreview(name, owner.current);
  };
  // A save that settles late passes the owner it started under: a newer preview (and the pointer's
  // pending dwell in a reopened list) belongs to someone else and is left alone.
  const end = (expectedOwner?: object) => {
    if (expectedOwner !== undefined && owner.current !== expectedOwner) return;
    if (expectedOwner === undefined) cancelDwell();
    if (showing.current !== null) {
      const currentOwner = owner.current;
      showing.current = null;
      owner.current = null;
      onPreview(null, currentOwner ?? undefined);
    }
  };
  const endOnUnmount = useRef(() => {});
  endOnUnmount.current = () => end();
  useEffect(() => () => endOnUnmount.current(), []);
  const highlight = (name: string | undefined, by: "keyboard" | "pointer" | "none") => {
    const target = name && name !== DEFAULT_FONT_ROW ? name : null;
    if (by === "keyboard") return preview(target);
    cancelDwell();
    if (target === showing.current) return;
    dwell.current = setTimeout(() => preview(target), DWELL_MS);
  };
  const dismiss = () => {
    closedAt.current = performance.now();
    setOpen(false);
    setQuery("");
  };
  const close = () => {
    cancelDwell();
    dismiss();
    end();
  };
  useEffect(() => {
    if (disabled && open) close();
  });
  // Write first, then end the preview: the app goes from the preview to the same saved font.
  const pick = (name: string) => {
    cancelDwell();
    dismiss();
    const chosen = name === DEFAULT_FONT_ROW ? null : names.includes(name) ? name : undefined;
    if (chosen === undefined || chosen === value) return end();
    const pickOwner = owner.current;
    void Promise.resolve(onPick(chosen)).finally(() => {
      if (pickOwner) end(pickOwner);
    });
  };
  const { rows, recent: recentRows } = fontRows({ names, recent, query });
  return (
    <span className="domain">
      <button
        ref={setAnchor}
        type="button"
        className="button domain-button"
        data-font-picker=""
        aria-labelledby={labelId}
        aria-haspopup="dialog"
        aria-expanded={open}
        disabled={disabled}
        style={value ? { fontFamily: fontFace(value) } : undefined}
        onClick={() => {
          if (open) close();
          else if (performance.now() - closedAt.current > 400) setOpen(true);
        }}
      >
        {value ?? defaultLabel}
        <Icon name="chevron" />
      </button>
      <Popover
        open={open && !disabled}
        onOpenChange={(next) => (next ? setOpen(true) : close())}
        anchor={anchor}
        label={title}
        className="domain-panel"
      >
        <Combobox
          inline
          suggestions={rows}
          onQuery={setQuery}
          onSubmit={pick}
          onCancel={close}
          onHighlight={highlight}
          label={title}
          placeholder={t("settingsPage.filter")}
          inputClassName="field font-search"
          listClassName="domain-list"
          itemClassName="domain-option"
          renderItem={(name) =>
            name === DEFAULT_FONT_ROW ? (
              <span className="font-option-row">
                <span className="font-option-name">{defaultLabel}</span>
                {value === null && <Icon name="check" className="font-option-check" />}
              </span>
            ) : (
              <span className="font-option-row" data-font-option={name}>
                <span className="font-option-name" style={{ fontFamily: fontFace(name) }}>
                  {name}
                </span>
                {recentRows.has(name) && <span className="font-option-tag">{t("settingsPage.font.recent")}</span>}
                {name === value && <Icon name="check" className="font-option-check" />}
              </span>
            )
          }
        />
        {rows.length === 0 && <output className="empty block">{t("settingsPage.font.noMatch")}</output>}
      </Popover>
    </span>
  );
}
