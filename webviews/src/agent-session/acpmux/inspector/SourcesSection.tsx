import { useState } from "react";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import type { SummarySource, SummarySourceKind } from "../summary/sessionSummary";

const ROW_ICON = rowIconSize(12);
export const SOURCES_SHOWN = 5;

const sourceIcon = (kind: SummarySourceKind | undefined) => {
  switch (kind) {
    case "pullRequest":
    case "issue":
      return "git.pullrequest";
    case "file":
      return "file.text";
    case "mcp":
      return "extension";
    default:
      return "link.web";
  }
};

/// References the session read or named. Sources are quiet rows: only URLs and pull requests
/// navigate, while files and MCP calls preserve the transcript's useful provenance.
export function SourcesSection({
  sources,
  onOpenBeside,
}: {
  sources: readonly SummarySource[];
  onOpenBeside?: (url: string) => void;
}) {
  const t = useT();
  const [all, setAll] = useState(false);
  const folds = sources.length > SOURCES_SHOWN;
  const shown = folds && !all ? sources.slice(0, SOURCES_SHOWN) : sources;
  return (
    <>
      <ul className="acpmux-chat-inspector-list" data-section="sources">
        {shown.map((source) => (
          <SourceRow
            key={`${source.kind ?? "url"}:${source.url ?? source.label}`}
            source={source}
            onOpenBeside={onOpenBeside}
          />
        ))}
      </ul>
      {folds && (
        <button
          type="button"
          className="acpmux-chat-inspector-fold acpmux-chat-inspector-sources-fold"
          aria-expanded={all}
          onClick={() => setAll(!all)}
        >
          {all ? t("summary.showFewer") : t("summary.viewAll", { n: sources.length })}
        </button>
      )}
    </>
  );
}

function SourceRow({ source, onOpenBeside }: { source: SummarySource; onOpenBeside?: (url: string) => void }) {
  const content = (
    <>
      <Icon name={sourceIcon(source.kind)} size={ROW_ICON} row />
      <span className="acpmux-chat-inspector-source__label">{source.label}</span>
    </>
  );
  if (!source.url) return <li className="acpmux-chat-inspector-source">{content}</li>;
  return (
    <li className="acpmux-chat-inspector-source">
      <a
        className="acpmux-chat-inspector-source__link"
        href={source.url}
        onClick={(event) => {
          if (!onOpenBeside || event.metaKey || event.ctrlKey || event.shiftKey) return;
          event.preventDefault();
          onOpenBeside(source.url!);
        }}
      >
        {content}
      </a>
    </li>
  );
}
