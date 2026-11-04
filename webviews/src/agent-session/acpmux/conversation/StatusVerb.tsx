import { useMemo } from "react";
import { usePaneLanguage, useT } from "../i18n";
import { statusVerbAt, statusVerbLabels, useStatusVerbConfig } from "../statusVerbs";

/// Decorative thinking copy on legacy live lines. Their existing page clock supplies elapsed
/// time; this component never starts a timer. Reserve every label's width without exposing the
/// sizing samples to copy or accessibility, and keep the accessible state stable while rotating.
export function StatusVerb({ elapsedMs }: { elapsedMs: number }) {
  const t = useT();
  const language = usePaneLanguage();
  const config = useStatusVerbConfig();
  const verbs = useMemo(() => statusVerbLabels(t, language, config), [t, language, config]);
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
      <span className="cv-status-verb__word">{statusVerbAt(elapsedMs, { mode: "custom", verbs })}</span>
    </output>
  );
}
