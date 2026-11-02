import { useEffect, useState } from "react";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import { NativeError } from "../nativeError";
import type { SummarySource } from "../summary/sessionSummary";

export const SOURCES_SHOWN = 5;
type RowProps = {
  source: SummarySource;
  onOpenBeside?: (url: string) => void;
  onOpenImage?: (src: string, alt: string) => void;
  /// A pasted image's bytes by its id, when its prompt did not carry them.
  readImage?: (id: string) => Promise<string | undefined>;
  onOpenFile?: (path: string) => unknown;
  cwd?: string;
};

// Native tab refusal preserves the gesture, so the validated editor route can retry.
export async function openSourceFile(
  path: string,
  native: (method: string, params: Record<string, unknown>) => Promise<unknown>,
) {
  try {
    return await native("file.open", { path, where: "tab" });
  } catch (error) {
    if (!(error instanceof NativeError) || error.code !== "transport.path_invalid") throw error;
    return native("file.open", { path, where: "editor" });
  }
}

function scopedPath(path: string, cwd?: string): string | undefined {
  if (!cwd?.startsWith("/") || path.startsWith("~") || path.includes("\0")) return;
  const normalize = (value: string) => {
    const parts: string[] = [];
    for (const part of value.split("/"))
      if (part === "..") parts.pop();
      else if (part && part !== ".") parts.push(part);
    return `/${parts.join("/")}`;
  };
  const root = normalize(cwd),
    resolved = normalize(path.startsWith("/") ? path : `${root}/${path}`);
  return resolved.startsWith(root === "/" ? root : `${root}/`) ? resolved : undefined;
}

export function SourcesSection({
  sources,
  expanded,
  onExpandedChange,
  ...navigation
}: Omit<RowProps, "source"> & {
  sources: readonly SummarySource[];
  expanded: boolean;
  onExpandedChange: (expanded: boolean) => void;
}) {
  const t = useT();
  const folds = sources.length > SOURCES_SHOWN;
  const shown = folds && !expanded ? sources.slice(0, SOURCES_SHOWN) : sources;
  return (
    <>
      <ul className="acpmux-session-info-list" data-section="sources">
        {shown.map((source) => (
          <SourceRow key={`${source.kind}:${source.url ?? source.label}`} source={source} {...navigation} />
        ))}
      </ul>
      {folds && (
        <button
          type="button"
          className="acpmux-session-info-fold acpmux-session-info-sources-fold"
          aria-expanded={expanded}
          onClick={() => onExpandedChange(!expanded)}
        >
          {expanded ? t("summary.showFewer") : t("summary.viewAll", { n: sources.length })}
        </button>
      )}
    </>
  );
}

function SourceRow({ source, onOpenBeside, onOpenImage, readImage, onOpenFile, cwd }: RowProps) {
  const t = useT();
  const [failure, setFailure] = useState<string>();
  useEffect(() => {
    if (!failure) return;
    const timer = setTimeout(() => setFailure(undefined), 4_000);
    return () => clearTimeout(timer);
  }, [failure]);
  const icon = {
    file: "file.text",
    mcp: "extension",
    pullRequest: "git.pullrequest",
    issue: "git.pullrequest",
    url: "link.web",
    image: "site.permission.images",
  } as const;
  const content = (
    <>
      <Icon name={icon[source.kind ?? "url"]} size={rowIconSize(12)} row />
      <span className="acpmux-session-info-source__label">{source.label || t("image.viewer")}</span>
    </>
  );
  const path = source.kind === "file" ? scopedPath(source.label, cwd) : undefined;
  const image = source.image;
  let target = content;
  if (image && onOpenImage && (image.src || readImage))
    target = (
      <button
        type="button"
        className="acpmux-session-info-source__link"
        onClick={() => {
          setFailure(undefined);
          Promise.resolve(image.src ?? readImage?.(image.id))
            .then((src) => {
              if (!src) throw new Error(t("image.unavailable"));
              onOpenImage(src, source.label || t("image.viewer"));
            })
            .catch((error: unknown) => setFailure(error instanceof Error ? error.message : t("image.actionFailed")));
        }}
      >
        {content}
      </button>
    );
  else if (path && onOpenFile)
    target = (
      <button
        type="button"
        className="acpmux-session-info-source__link"
        onClick={() => {
          setFailure(undefined);
          Promise.resolve()
            .then(() => onOpenFile(path))
            .catch((error: unknown) => setFailure(error instanceof Error ? error.message : t("changes.openFailed")));
        }}
      >
        {content}
      </button>
    );
  else if (source.kind !== "file" && source.url)
    target = (
      <a
        className="acpmux-session-info-source__link"
        href={source.url}
        onClick={(event) => {
          if (!onOpenBeside || event.metaKey || event.ctrlKey || event.shiftKey) return;
          event.preventDefault();
          onOpenBeside(source.url!);
        }}
      >
        {content}
      </a>
    );
  return <li className="acpmux-session-info-source">{failure ? <span role="alert">{failure}</span> : target}</li>;
}
