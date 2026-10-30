import React, { useContext, useEffect, useId, useRef, useState } from "react";
import type { Choice } from "./ComposerPickers";
import { isDefaultChoice } from "./defaultChoice";
import { EffortTrack } from "./EffortTrack";
import { useT } from "./i18n";
import { registerPicker } from "./pickerOpeners";
import { OnNewTab } from "./newTabComposer";
import { Menu, MenuButton, MenuGroup, MenuPopup, MenuRadioGroup, MenuRadioItem, MenuSeparator } from "../../ui/Menu";
import type { ReasoningSliderStyle } from "./composerSettings";

/// A switch section in the reasoning menu: Claude Code's Fast Mode (On/Off) or Codex's Service
/// Tier (Standard/Fast), and Claude Code's Ultracode. `on` is the choice the chip names.
export type SpeedSection = {
  title: string;
  choices: Choice[];
  current?: string;
  on: string;
  onPick(value: string): void;
};

/// The reasoning chip and its menu (Lawrence 2026-10-09, MonoCode's picker): a Reasoning section
/// with one checked row per level the model offers; then Ultracode and the speed section when the
/// agent has them. The agent's own level ("default", `defaulted`) checks the level it resolves to,
/// with a Default hint, and the chip names that level; unresolved, it says Reasoning, never the
/// first level. The chip says Ultracode while that is on. No composer draws it since Leo 2026-10-20
/// (one model button, its menu's Effort › and Fast mode rows, QuickModelMenu.tsx); it stays a
/// standalone control with its gallery.
/// The menu is the shared popup layer's opaque surface (ui/Menu), so nothing shows through it.
/// Picking sends chat.effort through `onPick` (and each section's own `onPick`).
/// With `slider` (the Debug Settings toggle `agent.reasoningSlider`, off by default) the Reasoning
/// section is the model picker's stepped slider (EffortTrack) instead of the rows, when the model
/// offers two or more levels. The slider picks as it moves and keeps the menu open; Escape closes
/// it back to the chip. `sliderStyle` is an opt-in visual comparison choice and defaults to the
/// current accent treatment.
export function EffortPicker({
  label,
  efforts,
  current,
  onPick,
  defaulted = false,
  ultracode,
  speed,
  chevron,
  short,
  slider = false,
  sliderStyle: requestedSliderStyle = "accent",
}: {
  /// The stable name automation opens it by (`openPicker`), whatever the UI language.
  label: string;
  efforts: Choice[];
  current?: string;
  onPick(value: string): void;
  /// The agent runs its own level; `current` is the level that resolves to.
  defaulted?: boolean;
  ultracode?: SpeedSection;
  speed?: SpeedSection;
  chevron?: React.ReactNode;
  /// The level's short name ("Med"), for a narrow composer row (composerRowFit.ts).
  short?: string;
  /// Draw the Reasoning section as a slider (the person's opt-in); the list is the default.
  slider?: boolean;
  /// Visual treatment for the opt-in slider; the current accent treatment is the default.
  sliderStyle?: ReasoningSliderStyle;
}) {
  const t = useT();
  // On New Tab the menu opens down (newTabComposer.ts).
  const newTab = useContext(OnNewTab);
  const [open, setOpen] = useState(false);
  // The agent's implicit level is represented by the chip, not a second "Default" row. Keep the
  // real levels in the menu so the first arrow lands on an actionable choice.
  const visibleEfforts = efforts.filter((choice) => !isDefaultChoice(choice));
  const selectedVisible = visibleEfforts.find((choice) => choice.id === current);
  const level =
    ultracode && ultracode.current === ultracode.on
      ? ultracode.title
      : (selectedVisible?.name ?? t("picker.reasoning"));
  // One level is nothing to slide between: the list shows it as a single checked row.
  const sliding = slider && visibleEfforts.length > 1;
  const sliderStyle = requestedSliderStyle;
  const recommended = visibleEfforts.find((choice) => choice.recommended);
  // The level the thumb shows: the picked one, else (the agent's own default) the recommended one.
  const shown = selectedVisible ?? recommended ?? visibleEfforts[0];
  // Automation opens the menu by its label as a click does (see pickerOpeners.ts).
  useEffect(() => registerPicker(label, () => setOpen(true)), [label]);
  // The slider focuses on mount in EffortTrack, so a delayed opening frame cannot take focus
  // back from a speed row reached by Down. For the list, Base UI initially focuses its popup; move
  // focus to the selected
  // reasoning row on the next frame, after the popup is mounted and positioned, so ArrowDown starts
  // from the visible choice for both a click and automation opening by label.
  useEffect(() => {
    if (!open || sliding) return;
    const frame = requestAnimationFrame(() => {
      const reasoningGroup = document.querySelector<HTMLElement>('.acpmux-effort-menu [role="group"]');
      const selectedReasoning =
        reasoningGroup?.querySelector<HTMLElement>('[role="menuitemradio"][aria-checked="true"]') ??
        reasoningGroup?.querySelector<HTMLElement>('[role="menuitemradio"]');
      selectedReasoning?.focus({ preventScroll: true });
    });
    return () => cancelAnimationFrame(frame);
  }, [open, sliding]);
  const levelRow = (choice: Choice) =>
    row(defaulted && choice.id === selectedVisible?.id ? { ...choice, hint: t("picker.default") } : choice);
  // One line per row, as a native menu: the label, a hint, and a short note (Ultracode) in secondary
  // text on the same line, its full text in the tooltip when the menu clips it, then the check in its
  // own trailing gutter (composerControls.css; empty when the row is not chosen, so every label
  // starts at the same x).
  const row = (choice: Choice) => (
    <MenuRadioItem key={choice.id} value={choice.id} className="acpmux-effort-item">
      <span className="acpmux-effort-text">
        <span className="acpmux-menu-label">{choice.name}</span>
        {choice.hint && (
          <span className="acpmux-effort-hint rounded border-[length:var(--cmux-hairline,0.5px)] border-edge px-1 text-caption text-dim">
            {choice.hint}
          </span>
        )}
        {choice.description && (
          // tooltip-allow: the note is cut with an ellipsis when the menu is narrow; the tooltip is its whole text
          <span className="acpmux-effort-detail" title={choice.description}>
            {choice.description}
          </span>
        )}
      </span>
    </MenuRadioItem>
  );
  return (
    <span className="acpmux-picker acpmux-effort">
      <Menu open={open} onOpenChange={setOpen}>
        <MenuButton className="acpmux-picker-button" label={t("effort.title")} data-menu={label} aria-haspopup="menu">
          <EffortLabel label={level} short={short && short !== level ? short : undefined} />
          {chevron}
        </MenuButton>
        <MenuPopup side={newTab ? "bottom" : "top"} align="start" className="acpmux-effort-menu">
          {sliding && (
            <ReasoningSlider
              title={t("picker.reasoning")}
              efforts={visibleEfforts}
              current={selectedVisible?.id}
              shown={shown}
              fallback={recommended?.id}
              sliderStyle={sliderStyle}
              onPick={onPick}
              onClose={() => setOpen(false)}
            />
          )}
          {!sliding && visibleEfforts.length > 0 && (
            <MenuGroup label={t("picker.reasoning")}>
              <MenuRadioGroup
                value={selectedVisible?.id ?? ""}
                onValueChange={(next) => {
                  onPick(next);
                  setOpen(false);
                }}
              >
                {visibleEfforts.map(levelRow)}
              </MenuRadioGroup>
            </MenuGroup>
          )}
          {[ultracode, speed].map((section, index) => {
            if (!section) return null;
            const rows = (
              <MenuRadioGroup
                value={section.current ?? ""}
                onValueChange={(next) => {
                  section.onPick(next);
                  setOpen(false);
                }}
              >
                {section.choices.map(row)}
              </MenuRadioGroup>
            );
            const first = index === 0 || !ultracode;
            return (
              <React.Fragment key={section.title}>
                <MenuSeparator />
                <MenuGroup label={section.title}>
                  {sliding && first ? (
                    // Up from the first row under the slider climbs back to it; it is not a menu row.
                    <div
                      className="contents"
                      // ui-allow: the menu's own row navigation cannot reach a non-row control.
                      onKeyDownCapture={toSliderFromFirstRow}
                    >
                      {rows}
                    </div>
                  ) : (
                    rows
                  )}
                </MenuGroup>
              </React.Fragment>
            );
          })}
        </MenuPopup>
      </Menu>
    </span>
  );
}

/// The effort chip's label: the level, and its short name for a narrow composer row, which swaps
/// one for the other whole (composerRowFit.ts). The short name is drawn, so the chip's text stays
/// the level's name.
function EffortLabel({ label, short }: { label: string; short?: string | undefined }) {
  if (!short) return <span>{label}</span>;
  return (
    <>
      <span data-fit-part="effort" data-fit-forms="full">
        {label}
      </span>
      <span className="acpmux-fit-label" data-fit-part="effort" data-fit-forms="short" data-label={short} />
    </>
  );
}

/// Keys the slider steps by itself, so the menu's own row navigation and typeahead never see them.
const SLIDER_KEYS = new Set(["ArrowLeft", "ArrowRight", "Home", "End", "PageUp", "PageDown"]);

/// The Reasoning section as a slider: its title and the level it sits on, then the track. Left,
/// Right, Home and End step it; Up and Down step it too unless the speed rows follow, where Down
/// moves to them (and Up from the first climbs back). Enter closes the menu as a row would, and
/// Escape closes it back to the chip. While the chat is on the agent's own default the thumb rests
/// on the recommended level without picking it; Enter or a click on the slider picks that level.
function ReasoningSlider({
  title,
  efforts,
  current,
  shown,
  fallback,
  sliderStyle,
  onPick,
  onClose,
}: {
  title: string;
  efforts: Choice[];
  current?: string;
  shown?: Choice;
  fallback?: string;
  sliderStyle: ReasoningSliderStyle;
  onPick(value: string): void;
  onClose(): void;
}) {
  const titleId = useId();
  // The host echoes `current` back after a pick, so the click that ends a drag (or a second Enter)
  // must not resend the level that was just sent.
  const sent = useRef<string | undefined>(undefined);
  useEffect(() => {
    sent.current = undefined;
  }, [current]);
  const commit = (value: string | undefined) => {
    if (value === undefined || value === current || value === sent.current) return;
    sent.current = value;
    onPick(value);
  };
  // The resting thumb (the agent's own default) is not a pick yet: Enter or a click takes it,
  // unless the slider already moved since (that pick stands; the input waits on the host's echo).
  const commitResting = () => {
    if (current === undefined && sent.current === undefined) commit(shown?.id);
  };
  const onRangeKey = (event: React.KeyboardEvent<HTMLInputElement>) => {
    if (SLIDER_KEYS.has(event.key)) {
      event.stopPropagation();
      return;
    }
    if (event.key === "Enter") {
      event.preventDefault();
      event.stopPropagation();
      commitResting();
      onClose();
      return;
    }
    if (event.key !== "ArrowUp" && event.key !== "ArrowDown") return;
    event.stopPropagation();
    const below = event.currentTarget
      .closest(".acpmux-effort-menu")
      ?.querySelector<HTMLElement>('[role="menuitemradio"]');
    if (!below) return;
    // With rows below, vertical arrows travel the menu as they do in any menu.
    event.preventDefault();
    if (event.key === "ArrowDown") below.focus();
  };
  return (
    // A group (a fieldset), as the list's MenuGroup is: the menu holds groups, rows and separators.
    <fieldset className="acpmux-effort-slider" aria-labelledby={titleId}>
      <div className="acpmux-effort-slider-head">
        <span id={titleId} className="ui-menu-group-label">
          {title}
        </span>
        {/* tooltip-allow: the slider row shows only the level's name; the tooltip is its description */}
        <span className="acpmux-effort-slider-level" title={shown?.description}>
          {shown?.name}
        </span>
      </div>
      <EffortTrack
        efforts={efforts}
        current={current}
        fallback={fallback}
        sliderStyle={sliderStyle}
        onPick={commit}
        onEscape={onClose}
        onRangeKey={onRangeKey}
        onRangeClick={commitResting}
        focusOnMount
      />
    </fieldset>
  );
}

/// ArrowUp on the first row under the slider (Ultracode's or the speed section's) focuses the slider above it instead of wrapping to the last row.
function toSliderFromFirstRow(event: React.KeyboardEvent<HTMLElement>) {
  if (event.key !== "ArrowUp") return;
  const menu = (event.target as HTMLElement).closest(".acpmux-effort-menu");
  const first = menu?.querySelector<HTMLElement>('[role="menuitemradio"]');
  if (!menu || event.target !== first) return;
  event.preventDefault();
  event.stopPropagation();
  menu.querySelector<HTMLElement>(".acpmux-effort-range")?.focus();
}
