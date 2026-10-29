import React, { useContext, useEffect, useId, useRef, useState } from "react";
import { usePopupHost } from "../../ui/UiProvider";
import { Menu, MenuButton, MenuGroup, MenuPopup, MenuRadioGroup, MenuRadioItem, MenuSeparator } from "../../ui/Menu";
import { EffortTrack } from "./EffortTrack";
import type { Choice } from "./ComposerPickers";
import { isDefaultChoice } from "./defaultChoice";
import { useT } from "./i18n";
import { registerPicker } from "./pickerOpeners";
import { OnNewTab } from "./newTabComposer";
import { useComposerPopup, popupChoice, popupSection, popupIdentity } from "./nativeComposerPopup";
import type { NativePopupEvent, NativePopupRow } from "../../ui/nativePopup";
import type { ReasoningSliderStyle } from "./composerSettings";

export type SpeedSection = {
  title: string;
  choices: Choice[];
  current?: string;
  on: string;
  onPick(value: string): void;
};

/** AppKit renders with native transport; browser previews keep the shared web menu. */
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
  sliderStyle = "accent",
}: {
  label: string;
  efforts: Choice[];
  current?: string;
  onPick(value: string): void;
  defaulted?: boolean;
  ultracode?: SpeedSection;
  speed?: SpeedSection;
  chevron?: React.ReactNode;
  short?: string;
  slider?: boolean;
  sliderStyle?: ReasoningSliderStyle;
}) {
  const t = useT();
  const native = usePopupHost()?.native;
  const newTab = useContext(OnNewTab);
  const [open, setOpen] = useState(false);
  const trigger = useRef<HTMLButtonElement>(null);
  const visibleEfforts = efforts.filter((choice) => !isDefaultChoice(choice));
  const selectedVisible = visibleEfforts.find((choice) => choice.id === current);
  const level =
    ultracode && ultracode.current === ultracode.on
      ? ultracode.title
      : (selectedVisible?.name ?? t("picker.reasoning"));
  const recommended = visibleEfforts.find((choice) => choice.recommended);
  const sliderShown = selectedVisible ?? recommended ?? visibleEfforts[0];
  const sliding = slider && visibleEfforts.length > 1;
  // Match the browser slider's commit guard while the host is still echoing a pick.
  const nativeSliderSent = useRef<string | undefined>(undefined);
  useEffect(() => {
    nativeSliderSent.current = undefined;
  }, [current, open]);

  useEffect(() => registerPicker(label, () => setOpen(true)), [label]);

  // Base UI initially focuses the popup while it measures its anchor. Move focus to the selected
  // reasoning row on the next frame, after the popup is mounted and positioned, so ArrowDown starts
  // from the visible choice for both a click and automation opening by label.
  useEffect(() => {
    if (native || !open) return;
    const frame = requestAnimationFrame(() => {
      const range = document.querySelector<HTMLElement>(".acpmux-effort-menu .acpmux-effort-range");
      if (range) {
        range.focus({ preventScroll: true });
        return;
      }
      const reasoningGroup = document.querySelector<HTMLElement>('.acpmux-effort-menu [role="group"]');
      const selectedReasoning =
        reasoningGroup?.querySelector<HTMLElement>('[role="menuitemradio"][aria-checked="true"]') ??
        reasoningGroup?.querySelector<HTMLElement>('[role="menuitemradio"]');
      selectedReasoning?.focus({ preventScroll: true });
    });
    return () => cancelAnimationFrame(frame);
  }, [native, open]);

  const rows: NativePopupRow[] = [];
  if (visibleEfforts.length > 0) {
    if (sliding) {
      const shownIndex = Math.max(
        0,
        visibleEfforts.findIndex((choice) => choice.id === sliderShown?.id),
      );
      rows.push({
        id: "reasoning-slider",
        kind: "slider",
        label: t("picker.reasoning"),
        value: String(shownIndex),
        minimum: 0,
        maximum: visibleEfforts.length - 1,
        step: 1,
        slider: {
          stops: visibleEfforts.map((choice) => ({
            value: choice.id,
            label: choice.name,
            description: choice.description,
            accessibilityLabel: choice.recommended
              ? t("effort.valueRecommended", { level: choice.name })
              : choice.name,
          })),
          selectedValue: selectedVisible?.id,
          defaultValue: recommended?.id ?? visibleEfforts[0]?.id,
          recommendedValue: recommended?.id,
          recommendedLabel: recommended
            ? t("effort.recommendedLevel", { level: recommended.name })
            : undefined,
          minimumLabel: t("effort.faster"),
          maximumLabel: t("effort.smarter"),
          accessibilityLabel: t("effort.title"),
          style: sliderStyle,
        },
      });
    } else {
      rows.push(
        ...popupSection(
          "reasoning",
          t("picker.reasoning"),
          visibleEfforts.map((choice) =>
            popupChoice(popupIdentity("effort", choice.id), choice.name, {
              description: choice.description,
              checked: choice.id === selectedVisible?.id,
              shortcut: defaulted && choice.id === selectedVisible?.id ? t("picker.default") : choice.hint,
            }),
          ),
        ),
      );
    }
  }
  for (const [index, section] of [ultracode, speed].entries()) {
    if (!section) continue;
    rows.push({ id: `separator-${index}`, kind: "separator", label: "" });
    rows.push(
      ...popupSection(
        `section-${index}`,
        section.title,
        section.choices.map((choice) =>
          popupChoice(popupIdentity(index === 0 ? "ultracode" : "speed", choice.id), choice.name, {
            description: choice.description,
            checked: choice.id === section.current,
            shortcut: choice.hint,
          }),
        ),
      ),
    );
  }
  const choiceById = new Map<string, { value: string; onPick(value: string): void }>();
  visibleEfforts.forEach((choice) => choiceById.set(popupIdentity("effort", choice.id), { value: choice.id, onPick }));
  for (const [index, section] of [ultracode, speed].entries()) {
    if (!section) continue;
    for (const choice of section.choices)
      choiceById.set(popupIdentity(index === 0 ? "ultracode" : "speed", choice.id), {
        value: choice.id,
        onPick: section.onPick,
      });
  }

  const pickChoice = (id: string) => {
    const choice = choiceById.get(id);
    if (!choice) return;
    choice.onPick(choice.value);
    setOpen(false);
  };

  useComposerPopup({
    open: Boolean(native) && open,
    anchor: () => trigger.current,
    model: {
      side: newTab ? "bottom" : "top",
      align: "start",
      width: 280,
      title: label,
      rows,
      highlighted: sliding
        ? "reasoning-slider"
        : selectedVisible
          ? popupIdentity("effort", selectedVisible.id)
          : undefined,
    },
    onEvent: (event: NativePopupEvent) => {
      if (event.type === "change" && event.id === "reasoning-slider") {
        if (!sliding || !event.value?.trim()) return;
        const index = Number(event.value);
        const choice = Number.isInteger(index) ? visibleEfforts[index] : undefined;
        if (choice && choice.id !== selectedVisible?.id && choice.id !== nativeSliderSent.current) {
          nativeSliderSent.current = choice.id;
          onPick(choice.id);
        }
        return;
      }
      if (event.type !== "pick" || !event.id) return;
      pickChoice(event.id);
    },
    onDismiss: () => setOpen(false),
  });

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
  if (!native)
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
                shown={sliderShown}
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
                    pickChoice(popupIdentity("effort", next));
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
                    pickChoice(popupIdentity(index === 0 ? "ultracode" : "speed", next));
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

  return (
    <span className="acpmux-picker acpmux-effort">
      <button
        ref={trigger}
        type="button"
        className="acpmux-picker-button"
        aria-label={t("effort.title")}
        data-menu={label}
        aria-haspopup="menu"
        aria-expanded={open}
        onClick={() => setOpen((was) => !was)}
      >
        <EffortLabel label={level} short={short && short !== level ? short : undefined} />
        {chevron}
      </button>
    </span>
  );
}

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
