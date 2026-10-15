import type { AcpmuxActivity } from "../model";
import { useT } from "../i18n";

/// A thought (the agent's reasoning) in full on its row: a muted "Thought", then the text wrapped
/// on the tool rows' rhythm (Leo 2026-10-13). Nothing to open and nothing on hover: a one-line
/// title cut the thought short and showed the rest only as a tooltip.
export function ThoughtRow({ item }: { item: AcpmuxActivity }) {
  const t = useT();
  const text = item.text.trim();
  if (!text) return null;
  return (
    <div className="cv-tool cv-thought">
      <span className="cv-thought__label" data-find-skip>
        {t("tools.thought")}
      </span>
      <span className="cv-thought__text selectable" dir="auto">
        {text}
      </span>
    </div>
  );
}
