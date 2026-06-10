import { getFiletypeFromFileName, type FileDiffMetadata } from "@pierre/diffs";
import type { DiffViewerLabelResolver } from "./labels";

// Short, friendly language labels for the file-header badge (Graphite shows the
// language next to the path). Falls back to an uppercased extension so every
// file still gets a tidy badge without an exhaustive map.
const LANGUAGE_LABELS: Record<string, string> = {
  typescript: "TS",
  tsx: "TSX",
  javascript: "JS",
  jsx: "JSX",
  json: "JSON",
  swift: "Swift",
  python: "Python",
  rust: "Rust",
  go: "Go",
  ruby: "Ruby",
  java: "Java",
  kotlin: "Kotlin",
  c: "C",
  cpp: "C++",
  csharp: "C#",
  css: "CSS",
  scss: "SCSS",
  html: "HTML",
  markdown: "MD",
  shellscript: "Shell",
  bash: "Shell",
  yaml: "YAML",
  toml: "TOML",
  sql: "SQL",
  zig: "Zig",
  objc: "Obj-C",
  objcpp: "Obj-C++",
};

export function diffFileLanguageLabel(fileDiff: FileDiffMetadata): string {
  const detected = fileDiff.lang ?? getFiletypeFromFileName(fileDiff.name) ?? "";
  // `getFiletypeFromFileName` returns "text" as a catch-all; treat that as "no
  // language" so plain/unknown files don't all get a noisy "TEXT" badge.
  const lang = detected === "text" ? "" : detected;
  if (lang && LANGUAGE_LABELS[lang]) {
    return LANGUAGE_LABELS[lang];
  }
  const extension = fileDiff.name.includes(".") ? fileDiff.name.split(".").pop() ?? "" : "";
  if (extension && extension.length <= 5) {
    return extension.toUpperCase();
  }
  return lang ? lang.toUpperCase() : "";
}

export function diffFileLineTotals(fileDiff: FileDiffMetadata): { additions: number; deletions: number } {
  let additions = 0;
  let deletions = 0;
  for (const hunk of fileDiff.hunks ?? []) {
    additions += hunk.additionLines ?? 0;
    deletions += hunk.deletionLines ?? 0;
  }
  return { additions, deletions };
}

/**
 * Graphite-style file header: a muted directory prefix with an emphasized
 * filename, a language badge, and +N/-N counts. Rendered by @pierre/diffs'
 * `renderCustomHeader` prop (a React node portaled into the virtualized file's
 * `<slot name="header-custom">`), so it lives in the light DOM and its styles
 * live in `styles.css` alongside the rest of the diff-viewer chrome.
 */
export function DiffFileHeader({
  fileDiff,
  label,
}: {
  fileDiff: FileDiffMetadata;
  label?: DiffViewerLabelResolver;
}) {
  const name = fileDiff.name ?? "";
  const slash = name.lastIndexOf("/");
  const directory = slash >= 0 ? name.slice(0, slash + 1) : "";
  const filename = slash >= 0 ? name.slice(slash + 1) : name;
  const badge = diffFileLanguageLabel(fileDiff);
  const { additions, deletions } = diffFileLineTotals(fileDiff);
  const title = fileDiff.prevName ? `${fileDiff.prevName} → ${name}` : name;

  return (
    <div className="cmux-fileheader">
      <span className="cmux-fileheader-path" title={title}>
        {directory ? <span className="cmux-fileheader-dir">{directory}</span> : null}
        <span className="cmux-fileheader-name">{filename}</span>
      </span>
      <span className="cmux-fileheader-meta">
        {badge ? <span className="cmux-fileheader-lang">{badge}</span> : null}
        {additions > 0 ? (
          <span className="cmux-fileheader-add" title={label?.("additions")}>
            {`+${additions}`}
          </span>
        ) : null}
        {deletions > 0 ? (
          <span className="cmux-fileheader-del" title={label?.("deletions")}>
            {`−${deletions}`}
          </span>
        ) : null}
      </span>
    </div>
  );
}
