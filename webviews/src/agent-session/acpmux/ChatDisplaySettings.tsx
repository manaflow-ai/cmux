// The chat's Text & Width popover (plans/cmux-next/chat-display-settings-DESIGN.md, layout A of
// the chat-display-menu gallery): the ··· menu's "Text & Width…" opens it under the menu button.
// Each row is one `agentPane.display.*` key (chatDisplay.ts CHAT_DISPLAY; the same rows are in
// Settings > Appearance > Agent Chat and cmux.json). A change shows at once and is written through
// the host. The font, code font and code size read "Same as Markdown Viewer" until set; Reset
// removes every key.
import { useEffect, useId, useRef, useState } from "react";
import { Popover, type UiAnchor } from "../../ui/Popover";
import { useT } from "./i18n";
import {
  CHAT_DISPLAY,
  changeChatDisplay,
  chatDisplayValues,
  resetChatDisplay,
  useChatDisplay,
  type ChatFontChoice,
} from "./chatDisplay";

/// Code fonts offered beside a typed name; empty follows the Markdown viewer, then the terminal font.
export const CODE_FONT_SUGGESTIONS = ["SF Mono", "Menlo", "Monaco", "JetBrains Mono", "Fira Code", "Berkeley Mono"];

const shown = (value: number) => String(Number(value.toFixed(2)));

export function ChatDisplaySettings({
  open,
  onOpenChange,
  anchor,
}: {
  open: boolean;
  onOpenChange: (open: boolean) => void;
  anchor: UiAnchor;
}) {
  const t = useT();
  return (
    <Popover
      open={open}
      onOpenChange={(next) => onOpenChange(next)}
      anchor={anchor}
      label={t("chatDisplay.title")}
      className="acpmux-display"
      side="bottom"
    >
      <ChatDisplayRows />
    </Popover>
  );
}

/// The popover's rows (the gallery draws them in place, without a popover).
export function ChatDisplayRows() {
  const t = useT();
  const display = useChatDisplay();
  const own = chatDisplayValues();
  const fontChoice = (own[CHAT_DISPLAY.font.key] as ChatFontChoice | undefined) ?? "markdown";
  const codeFamily =
    typeof own[CHAT_DISPLAY.codeFamily.key] === "string" ? (own[CHAT_DISPLAY.codeFamily.key] as string) : "";
  const [codeFamilyDraft, setCodeFamilyDraft] = useState(codeFamily);
  const editingCodeFamily = useRef(false);
  useEffect(() => {
    if (!editingCodeFamily.current) setCodeFamilyDraft(codeFamily);
  }, [codeFamily]);
  const listId = useId();
  const c = CHAT_DISPLAY;
  const commitCodeFamily = () => {
    editingCodeFamily.current = false;
    const value = codeFamilyDraft.trim();
    setCodeFamilyDraft(value);
    changeChatDisplay(c.codeFamily.key, value || null);
  };
  return (
    <div className="acpmux-display-body">
      <Slider
        label={t("chatDisplay.width")}
        value={display.width}
        range={c.width}
        display={t("chatDisplay.points", { value: shown(display.width) })}
        disabled={display.fullWidth}
        onChange={(value) => changeChatDisplay(c.width.key, value)}
      />
      <label className="acpmux-display-row acpmux-display-check">
        <input
          type="checkbox"
          aria-label={t("chatDisplay.fullWidth")}
          checked={display.fullWidth}
          onChange={(event) => changeChatDisplay(c.fullWidth.key, event.currentTarget.checked ? true : null)}
        />
        <span>{t("chatDisplay.fullWidth")}</span>
      </label>
      <label className="acpmux-display-row">
        <span>{t("chatDisplay.font")}</span>
        <select
          aria-label={t("chatDisplay.font")}
          value={fontChoice}
          onChange={(event) =>
            changeChatDisplay(c.font.key, event.currentTarget.value === "markdown" ? null : event.currentTarget.value)
          }
        >
          <option value="markdown">{t("chatDisplay.sameAsMarkdown")}</option>
          <option value="system">{t("chatDisplay.fontSystem")}</option>
          <option value="serif">{t("chatDisplay.fontSerif")}</option>
          <option value="mono">{t("chatDisplay.fontMono")}</option>
        </select>
      </label>
      <Slider
        label={t("chatDisplay.fontSize")}
        value={display.fontSize}
        range={c.fontSize}
        display={t("chatDisplay.points", { value: shown(display.fontSize) })}
        onChange={(value) => changeChatDisplay(c.fontSize.key, value)}
      />
      <Slider
        label={t("chatDisplay.lineHeight")}
        value={display.lineHeight}
        range={c.lineHeight}
        display={shown(display.lineHeight)}
        onChange={(value) => changeChatDisplay(c.lineHeight.key, value)}
      />
      <label className="acpmux-display-row">
        <span>{t("chatDisplay.codeFont")}</span>
        <input
          type="text"
          aria-label={t("chatDisplay.codeFont")}
          list={listId}
          value={codeFamilyDraft}
          placeholder={display.codeFamily ?? t("chatDisplay.sameAsMarkdown")}
          spellCheck={false}
          onChange={(event) => {
            editingCodeFamily.current = true;
            const value = event.currentTarget.value;
            setCodeFamilyDraft(value);
            // Preview valid input immediately, while keeping the raw draft so a trailing space
            // can be typed before the next word in a multi-word family name.
            changeChatDisplay(c.codeFamily.key, value.trim() || null);
          }}
          onBlur={commitCodeFamily}
          onKeyDown={(event) => {
            if (event.key !== "Enter") return;
            event.preventDefault();
            commitCodeFamily();
          }}
        />
        <datalist id={listId}>
          {CODE_FONT_SUGGESTIONS.map((name) => (
            <option key={name} value={name}>
              {name}
            </option>
          ))}
        </datalist>
      </label>
      <Slider
        label={t("chatDisplay.codeSize")}
        value={display.codeScale ?? c.codeScale.fallback}
        range={c.codeScale}
        display={`${Math.round((display.codeScale ?? c.codeScale.fallback) * 100)}%`}
        onChange={(value) => changeChatDisplay(c.codeScale.key, value)}
      />
      <button type="button" className="acpmux-display-reset" onClick={resetChatDisplay}>
        {t("chatDisplay.reset")}
      </button>
    </div>
  );
}

function Slider({
  label,
  value,
  range,
  display,
  disabled = false,
  onChange,
}: {
  label: string;
  value: number;
  range: { min: number; max: number; step: number };
  display: string;
  disabled?: boolean;
  onChange: (value: number) => void;
}) {
  return (
    <label className="acpmux-display-row">
      <span>{label}</span>
      <input
        type="range"
        aria-label={label}
        min={range.min}
        max={range.max}
        step={range.step}
        value={value}
        disabled={disabled}
        onChange={(event) => onChange(Number(event.currentTarget.value))}
      />
      <output>{display}</output>
    </label>
  );
}
