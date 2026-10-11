import React, { useRef, type CSSProperties } from "react";
import { ChoiceGroup } from "../../../ui/ChoiceGroup";
import { useNt } from "./strings";
import { NEW_TAB_TEMPLATES, type NewTabTemplate } from "./templates";

/// The template switcher at the bottom of the New Tab page (cx-l1jv), drawn like the sidebar's
/// space dots: one dot per template in its own slot, a hover chip under the pointer, and the
/// current template's chip sliding to the dot picked. The dots are native radios, so the arrow
/// keys switch templates in place. Terminal turns the page into a terminal, so arrowing onto it
/// only focuses it; a click or Return opens it. A dot's name is its tooltip and accessible label.
/// `fromKeys` is true when the pick came from the keyboard, which keeps focus on the dots: no
/// pointer went down on a dot just before it (`:focus-visible` does not tell in WebKit).
export function TemplateDots({
  current,
  onPick,
  onCancel,
}: {
  current: NewTabTemplate;
  onPick(template: NewTabTemplate, fromKeys: boolean): void;
  onCancel(): void;
}) {
  const nt = useNt();
  const pressedAt = useRef(Number.NEGATIVE_INFINITY);
  const pointed = (time: number) => time - pressedAt.current < 1000;
  const focused = () => {
    const element = document.activeElement;
    return element instanceof HTMLInputElement && element.classList.contains("nt-template-input") ? element : undefined;
  };
  const chip = { "--nt-template-index": NEW_TAB_TEMPLATES.indexOf(current) } as CSSProperties;
  return (
    <ChoiceGroup
      label={nt("templates")}
      className="nt-templates"
      onSubmit={() => {
        const template = NEW_TAB_TEMPLATES.find((choice) => choice === focused()?.value);
        if (template && (template !== current || template === "terminal")) onPick(template, true);
      }}
      onCancel={onCancel}
    >
      <span className="nt-templates-chip" aria-hidden="true" style={chip} />
      {NEW_TAB_TEMPLATES.map((template) => {
        const name = nt(`template.${template}`);
        return (
          <label
            key={template}
            className="nt-template-dot"
            data-template={template}
            title={name}
            onPointerDown={(event) => (pressedAt.current = event.timeStamp)}
          >
            <input
              type="radio"
              className="nt-template-input"
              name="nt-template"
              value={template}
              aria-label={name}
              checked={template === current}
              onChange={(event) => template !== "terminal" && onPick(template, !pointed(event.timeStamp))}
              // A pointer opens Terminal; the arrow keys only focus it.
              onClick={(event) => template === "terminal" && pointed(event.timeStamp) && onPick(template, false)}
            />
          </label>
        );
      })}
    </ChoiceGroup>
  );
}
