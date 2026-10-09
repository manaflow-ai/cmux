import React from "react";
import { useNt } from "./strings";
import { NEW_TAB_TEMPLATES, type NewTabTemplate } from "./templates";

/// The template switcher at the bottom of the New Tab page: one dot per template, the shown one
/// pressed. A dot's name is its tooltip and accessible label.
export function TemplateDots({
  current,
  onPick,
}: {
  current: NewTabTemplate;
  onPick(template: NewTabTemplate): void;
}) {
  const nt = useNt();
  return (
    <div className="nt-templates" role="group" aria-label={nt("templates")}>
      {NEW_TAB_TEMPLATES.map((template) => {
        const name = nt(`template.${template}`);
        return (
          <button
            key={template}
            type="button"
            className="nt-template-dot"
            data-template={template}
            aria-label={name}
            aria-pressed={template === current}
            title={name}
            onClick={() => (template !== current || template === "terminal") && onPick(template)}
          />
        );
      })}
    </div>
  );
}
