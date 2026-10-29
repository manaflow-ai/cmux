import React, { useContext, useEffect, useRef, useState } from "react";
import type { Choice } from "./ComposerPickers";
import { isDefaultChoice } from "./defaultChoice";
import { useT } from "./i18n";
import { registerPicker } from "./pickerOpeners";
import { OnNewTab } from "./newTabComposer";
import {
  useComposerPopup,
  popupChoice,
  popupSection,
} from "./nativeComposerPopup";
import type { NativePopupEvent, NativePopupRow } from "../../ui/nativePopup";
import type { ReasoningSliderStyle } from "./composerSettings";

export type SpeedSection = {
  title: string;
  choices: Choice[];
  current?: string;
  on: string;
  onPick(value: string): void;
};

/** Native-only effort/speed picker. The web owns labels and action IDs; AppKit owns popup UI. */
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
  sliderStyle: _sliderStyle = "accent",
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
  const newTab = useContext(OnNewTab);
  const [open, setOpen] = useState(false);
  const trigger = useRef<HTMLButtonElement>(null);
  const visibleEfforts = efforts.filter((choice) => !isDefaultChoice(choice));
  const selectedVisible = visibleEfforts.find(
    (choice) => choice.id === current,
  );
  const level =
    ultracode && ultracode.current === ultracode.on
      ? ultracode.title
      : (selectedVisible?.name ?? t("picker.reasoning"));
  const sliderShown =
    selectedVisible ??
    visibleEfforts.find((choice) => choice.recommended) ??
    visibleEfforts[0];

  useEffect(() => registerPicker(label, () => setOpen(true)), [label]);

  const rows: NativePopupRow[] = [];
  if (visibleEfforts.length > 0) {
    if (slider && visibleEfforts.length > 1) {
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
      });
    } else {
      rows.push(
        popupSection(
          "reasoning",
          t("picker.reasoning"),
          visibleEfforts.map((choice) =>
            popupChoice(choice.id, choice.name, {
              description: choice.description,
              checked: choice.id === selectedVisible?.id,
              ...(defaulted && choice.id === selectedVisible?.id
                ? { value: t("picker.default") }
                : {}),
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
      popupSection(
        `section-${section.title}`,
        section.title,
        section.choices.map((choice) =>
          popupChoice(choice.id, choice.name, {
            description: choice.description,
            checked: choice.id === section.current,
          }),
        ),
      ),
    );
  }
  const choiceById = new Map<
    string,
    { value: string; onPick(value: string): void }
  >();
  for (const choice of visibleEfforts)
    choiceById.set(choice.id, { value: choice.id, onPick });
  for (const section of [ultracode, speed]) {
    if (!section) continue;
    for (const choice of section.choices)
      choiceById.set(choice.id, { value: choice.id, onPick: section.onPick });
  }

  useComposerPopup({
    open,
    anchor: () => trigger.current,
    model: {
      side: newTab ? "bottom" : "top",
      align: "start",
      width: 280,
      title: label,
      rows,
      highlighted: selectedVisible?.id,
    },
    onEvent: (event: NativePopupEvent) => {
      if (event.type === "change" && event.id === "reasoning-slider") {
        const index = Number(event.value);
        const choice = Number.isInteger(index)
          ? visibleEfforts[index]
          : undefined;
        if (choice) onPick(choice.id);
        return;
      }
      if (event.type !== "pick" || !event.id) return;
      const choice = choiceById.get(event.id);
      if (choice) choice.onPick(choice.value);
    },
    onDismiss: () => setOpen(false),
  });

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
        <EffortLabel
          label={level}
          short={short && short !== level ? short : undefined}
        />
        {chevron}
      </button>
    </span>
  );
}

function EffortLabel({
  label,
  short,
}: {
  label: string;
  short?: string | undefined;
}) {
  if (!short) return <span>{label}</span>;
  return (
    <>
      <span data-fit-part="effort" data-fit-forms="full">
        {label}
      </span>
      <span
        className="acpmux-fit-label"
        data-fit-part="effort"
        data-fit-forms="short"
        data-label={short}
      />
    </>
  );
}
