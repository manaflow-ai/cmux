// The UI inspector on a stage (the gallery's `agent-pane.ui-inspector`): the real picker
// (picker.ts) installed over `children` and driven the way the native controller drives it, to one
// still state. Elements to point at carry `data-ui-pointer-target="<name>"`. Not used by the pane,
// which installs the picker itself (mountModel.tsx).
import React, { useLayoutEffect, useRef, type ReactNode } from "react";
import type { LabelDensity, LabelPlacement } from "./labelModel";

/** The state to drive to: picking started; an element hovered (then keys pressed); or held after Inspect Element. */
export type UiPointerStep =
  | { kind: "start" }
  | { kind: "hover"; target: string; keys?: string[] }
  | { kind: "held"; target: string };

export type UiPointerStageProps = {
  step: UiPointerStep;
  density?: LabelDensity;
  placement?: LabelPlacement;
  children?: ReactNode;
};

export function UiPointerStage({ step, density, placement, children }: UiPointerStageProps) {
  const root = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    let stop = () => {};
    let cancelled = false;
    void import("./picker").then(({ installUiPointer }) => {
      if (cancelled) return;
      const doc = root.current?.ownerDocument ?? document;
      const picker = installUiPointer(doc, { post: () => {}, label: { density, placement } });
      const centre = (name: string) => {
        const rect = doc.querySelector(`[data-ui-pointer-target="${name}"]`)?.getBoundingClientRect();
        return rect ? [rect.x + rect.width / 2, rect.y + rect.height / 2] : [0, 0];
      };
      const drive = () => {
        picker.stop();
        picker.start();
        if (step.kind === "hover") {
          const [x, y] = centre(step.target);
          picker.highlight(x, y);
          for (const key of step.keys ?? [])
            doc.defaultView?.dispatchEvent(new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true }));
        } else if (step.kind === "held") {
          const [x, y] = centre(step.target);
          picker.inspectMenuTarget(x, y);
        }
      };
      drive();
      // A resized stage (the gallery's width switch) drives again, to the same state at the new size.
      doc.defaultView?.addEventListener("resize", drive);
      stop = () => {
        doc.defaultView?.removeEventListener("resize", drive);
        picker.stop();
      };
    });
    return () => {
      cancelled = true;
      stop();
    };
  }, [step, density, placement]);
  return <div ref={root}>{children}</div>;
}
