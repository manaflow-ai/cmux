// Cards inside or beside a transcript: "Edited N files", the "open in another app" banner
// that replaces the composer, and the floating thread summary (Outputs / Sources).
import type { CSSProperties, ReactNode } from "react";
import { ChevronDown, Connectors, DiffFile, Lock, OpenAIMark, Plus, Undo } from "./icons";

export type EditedFile = { path: string; additions: number; deletions: number };

export type EditedFilesCardProps = {
  files: EditedFile[];
  /** Number of files shown before "Show N more files". */
  visible?: number;
  /** Totals; default sums `files`. */
  additions?: number;
  deletions?: number;
  /** Total count for the title; default `files.length`. */
  count?: number;
};

/** "Edited N files" card with Undo / View changes and the per-file list. */
export function EditedFilesCard({
  files,
  visible = 3,
  additions,
  deletions,
  count,
}: EditedFilesCardProps) {
  const add = additions ?? files.reduce((n, f) => n + f.additions, 0);
  const del = deletions ?? files.reduce((n, f) => n + f.deletions, 0);
  const total = count ?? files.length;
  // One edited file: the card names it and lists nothing (live-getappstate-bottom).
  const single = total === 1 && files.length === 1 ? files[0] : undefined;
  const shown = single ? [] : files.slice(0, visible);
  const more = single ? 0 : total - Math.min(visible, files.length);
  return (
    <div className="cv-edited">
      <div className="cv-edited__head">
        <span className="cv-edited__icon">
          <DiffFile size={20} strokeWidth={1.1} className="cv-edited__glyph" />
        </span>
        <div className="cv-edited__title">
          <div>
            {single
              ? `Edited ${single.path.slice(single.path.lastIndexOf("/") + 1)}`
              : `Edited ${total} ${total === 1 ? "file" : "files"}`}
          </div>
          <div className="cv-counts">
            <span className="cv-add">+{add}</span> <span className="cv-del">-{del}</span>
          </div>
        </div>
        <span className="cv-edited__undo">
          Undo <Undo size={14} strokeWidth={1.2} />
        </span>
        <span className="cv-edited__view">View changes</span>
      </div>
      {shown.map((f) => {
        const slash = f.path.lastIndexOf("/");
        return (
          <div key={f.path} className="cv-edited__file">
            <span className="cv-edited__path">
              <span className="cv-edited__dir">{f.path.slice(0, slash + 1)}</span>
              <span className="cv-edited__base">{f.path.slice(slash + 1)}</span>
            </span>
            <span className="cv-counts">
              <span className="cv-add">+{f.additions}</span>{" "}
              <span className="cv-del">-{f.deletions}</span>
            </span>
          </div>
        );
      })}
      {more > 0 && (
        <div className="cv-edited__more">
          Show {more} more {more === 1 ? "file" : "files"}
          <ChevronDown size={14} strokeWidth={1.2} />
        </div>
      )}
    </div>
  );
}

export type OpenElsewhereBannerProps = {
  title?: string;
  body?: string;
  actions?: string[];
  style?: CSSProperties;
};

/** "This is open in another app" banner that replaces the composer. */
export function OpenElsewhereBanner({
  title = "This is open in another app",
  body = "Close it there to continue here.",
  actions = ["Retry", "Fork chat"],
  style,
}: OpenElsewhereBannerProps) {
  return (
    <div className="cv-elsewhere" style={style}>
      <Lock className="cv-elsewhere__icon" size={16} strokeWidth={1.2} />
      <div className="cv-elsewhere__text">
        <div className="cv-elsewhere__title">{title}</div>
        <div className="cv-elsewhere__body">{body}</div>
      </div>
      <span className="cv-elsewhere__sep" />
      {actions.map((a) => (
        <span key={a} className="cv-elsewhere__action">
          {a}
        </span>
      ))}
    </div>
  );
}

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
export function ThreadSummary({
  sections,
  style,
}: {
  sections: SummarySection[];
  style?: CSSProperties;
}) {
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
            <div
              key={ii}
              className={`cv-summary__item is-${it.tone ?? "normal"}${it.icon ? " has-icon" : ""}`}
            >
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
