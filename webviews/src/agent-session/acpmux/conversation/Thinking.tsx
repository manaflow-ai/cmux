// "Thinking": a running turn before its first output. The label shimmers unless Reduce Motion
// is on (conversation.css).
import { useT } from "../i18n";

export function Thinking() {
  const t = useT();
  return (
    <output className="cv-worked">
      <span className="cv-thinking">{t("thinking")}</span>
    </output>
  );
}
