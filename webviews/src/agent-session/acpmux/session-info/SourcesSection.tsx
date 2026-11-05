import { useEffect, useState } from "react";
import { useT, type Translate } from "../i18n";
import { numberedImageLabels } from "../imageLabel";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import { NativeError } from "../nativeError";
import type { SummarySource } from "../summary/sessionSummary";
import { extraFolderName } from "../extraFolders";

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

/// Each source's row name, in order: a pasted image with no name of its own (WebKit's "image.png")
/// is "Screenshot 1", "Screenshot 2", ... in chat order, numbered across the whole list so a row
/// keeps its number when View all unfolds; every other source is its label.
export function sourceLabels(t: Translate, sources: readonly SummarySource[]): string[] {
  const images = sources.filter((source) => source.kind === "image");
  const named = numberedImageLabels(
    t,
    images.map((source) => ({ name: source.label, source: source.image?.source })),
  );
  const labels = new Map(images.map((source, index) => [source, named[index]!]));
  return sources.map((source) => labels.get(source) ?? source.label);
}

export function scopedPath(path: string, cwd?: string): string | undefined {
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
  folders = [],
  expanded,
  onExpandedChange,
  ...navigation
}: Omit<RowProps, "source"> & {
  sources: readonly SummarySource[];
  /// The folders the chat sees beside its own (acpmux `additionalDirectories`), listed first. Leo,
  /// 2026-11-03: "being able to have chatgpt (and in this case, any harnesses) see whatever
  /// folders/files would be cool".
  folders?: readonly string[];
  expanded: boolean;
  onExpandedChange: (expanded: boolean) => void;
}) {
  const t = useT();
  const folds = sources.length > SOURCES_SHOWN;
  const shown = folds && !expanded ? sources.slice(0, SOURCES_SHOWN) : sources;
  const labels = sourceLabels(t, sources);
  return (
    <>
      <ul className="acpmux-session-info-list" data-section="sources">
        {folders.map((folder) => (
          // tooltip-allow: the row shows the folder's name; the tooltip is its full path
          <li key={`folder:${folder}`} className="acpmux-session-info-source" data-kind="folder" title={folder}>
            <span className="acpmux-session-info-source__link">
              <Icon name="folder" size={rowIconSize(12)} row />
              <span className="acpmux-session-info-source__label">{extraFolderName(folder)}</span>
            </span>
          </li>
        ))}
        {shown.map((source, index) => (
          <SourceRow
            key={source.image ? `image:${source.image.id}` : `${source.kind}:${source.url ?? source.label}`}
            source={source}
            label={labels[index]!}
            {...navigation}
          />
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

function SourceRow({
  source,
  label,
  onOpenBeside,
  onOpenImage,
  readImage,
  onOpenFile,
  cwd,
}: RowProps & { label: string }) {
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
      <span className="acpmux-session-info-source__label">{label || t("image.viewer")}</span>
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
              onOpenImage(src, label || t("image.viewer"));
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
