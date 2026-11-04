// A tool's notice's severity mark (agentNotice.ts), drawn in the tool rows' icon column at the
// stroke glyphs' size: a fire is a filled red disc with a white "!", a warning an amber triangle,
// an info notice a quiet ring in the rows' muted tone. Never animated: a page that needs a person
// reads from its colour and shape, never a pulse or a blink (design/chat-transcript.md, the agent
// working-state rule).
import type { StringKey } from "../i18n";
import { useT } from "../i18n";
import type { NoticeSeverity } from "./agentNotice";
import "./NoticeMark.css";

export const SEVERITY_LABEL: Record<NoticeSeverity, StringKey> = {
  fire: "notice.severity.fire",
  warn: "notice.severity.warn",
  info: "notice.severity.info",
};

export function NoticeMark({ severity, size = 14 }: { severity: NoticeSeverity; size?: number }) {
  const t = useT();
  return (
    <svg className="cv-notice-mark" data-severity={severity} width={size} height={size} viewBox="0 0 16 16">
      <title>{t(SEVERITY_LABEL[severity])}</title>
      {severity === "fire" ? (
        <>
          <circle cx="8" cy="8" r="6.5" fill="currentColor" />
          <path className="cv-notice-mark__ink" d="M8 4.75v3.75" strokeWidth="1.6" strokeLinecap="round" />
          <circle className="cv-notice-mark__dot" cx="8" cy="11" r=".95" />
        </>
      ) : severity === "warn" ? (
        <>
          <path
            d="M8 2.4 14.2 13a.6.6 0 0 1-.52.9H2.32a.6.6 0 0 1-.52-.9Z"
            fill="none"
            stroke="currentColor"
            strokeWidth="1.3"
            strokeLinejoin="round"
          />
          <path d="M8 6.5v3" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" />
          <circle cx="8" cy="11.6" r=".7" fill="currentColor" />
        </>
      ) : (
        <>
          <circle cx="8" cy="8" r="5.75" fill="none" stroke="currentColor" strokeWidth="1.25" />
          <path d="M8 7.4v3.6" stroke="currentColor" strokeWidth="1.25" strokeLinecap="round" />
          <circle cx="8" cy="5.2" r=".7" fill="currentColor" />
        </>
      )}
    </svg>
  );
}
