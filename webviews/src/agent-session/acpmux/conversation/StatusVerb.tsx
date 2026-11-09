import { useContext, useMemo } from "react";
import { useT } from "../i18n";
import { statusVerbAt, statusVerbLabels, useStatusVerbConfig } from "../statusVerbs";
import { thinkingVerb, ThinkingVerbsContext } from "./thinkingVerbs";

/// Decorative thinking copy on legacy live lines. Their existing page clock supplies elapsed
/// time; this component never starts a timer. Reserve every label's width without exposing the
/// sizing samples to copy or accessibility, and keep the accessible state stable while rotating.
export function StatusVerb({ elapsedMs, verbKey }: { elapsedMs: number; verbKey?: string }) {
  const t = useT();
  const config = useStatusVerbConfig();
  const thinkingVerbs = useContext(ThinkingVerbsContext);
  const verbs = useMemo(() => thinkingVerbs ?? statusVerbLabels(t, config), [t, config, thinkingVerbs]);
  const sizes = useMemo(
    () =>
      verbs.map((word, index) => (
        <span key={index} className="cv-status-verb__size" data-text={word} aria-hidden="true" inert />
      )),
    [verbs],
  );
  return (
    <output className="cv-status-verb" aria-label={t("thinking")} aria-live="off">
      {sizes}
      <span className="cv-status-verb__word">
        {thinkingVerb(thinkingVerbs, verbKey) ??
          (config.mode === "custom" ? statusVerbAt(elapsedMs, { mode: "custom", verbs }) : t("thinking"))}
      </span>
    </output>
  );
}
