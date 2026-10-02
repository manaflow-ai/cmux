import { type CSSProperties, type ReactNode } from "react";
import { Connectors, DiffFile, OpenAIMark, Plus } from "./icons";

export type SummarySection = {
  title: string;
  /** Show the + button on the header row. */
  add?: boolean;
  /** Trailing ⋯ instead of +. */
  more?: boolean;
  items: {
    label: ReactNode;
    icon?: ReactNode | "openai" | "connectors" | "changes";
    tone?: "strong" | "normal" | "dim";
  }[];
};

/** Floating thread summary card (Outputs / Sources / project) at the main column's top right. */
export function ThreadSummary({ sections, style }: { sections: SummarySection[]; style?: CSSProperties }) {
  return (
    <div className="cv-summary" style={style}>
      {sections.map((s, si) => (
        <div key={si} className="cv-summary__section">
          <div className="cv-summary__head">
            <span>{s.title}</span>
            {s.add && <Plus size={16} strokeWidth={1.1} className="cv-summary__add" />}
            {s.more && (
              <svg
                className="cv-summary__more"
                width="16"
                height="16"
                viewBox="0 0 16 16"
                fill="currentColor"
                aria-hidden
              >
                <circle cx="3.5" cy="8" r="1.1" />
                <circle cx="8" cy="8" r="1.1" />
                <circle cx="12.5" cy="8" r="1.1" />
              </svg>
            )}
          </div>
          {s.items.map((it, ii) => (
            <div key={ii} className={`cv-summary__item is-${it.tone ?? "normal"}${it.icon ? " has-icon" : ""}`}>
              {it.icon === "openai" ? (
                <OpenAIMark size={16} className="cv-summary__icon" />
              ) : it.icon === "connectors" ? (
                <Connectors size={16} className="cv-summary__icon" />
              ) : it.icon === "changes" ? (
                <DiffFile size={16} strokeWidth={1.2} className="cv-summary__icon" />
              ) : it.icon ? (
                <span className="cv-summary__icon">{it.icon}</span>
              ) : null}
              <span>{it.label}</span>
            </div>
          ))}
        </div>
      ))}
    </div>
  );
}
