// Inline previews in the diff (the Codex Review pane's): an image file always shows its two sides,
// before and after, in place of its diff; with Rich preview on, a Markdown file shows its new
// version rendered. The code view draws only diffs, so a previewed file becomes a one-line file
// item whose line annotation holds the preview, and the viewer's CSS hides that line
// (pierre-options.ts `pre[data-file]`). Both sides come from the host's `fileContents`.
import { lazy, Suspense, useEffect, useState } from "react";
import type { DiffItem } from "../diff-stream";
import type { DiffViewerLabelResolver } from "../labels";
import {
  imageDataURL,
  markdownText,
  previewEncodingOf,
  previewKindOf,
  type FileContents,
  type FileContentsLoader,
  type PreviewKind,
} from "./richPreview";

/** The annotation a preview item carries on its one line. */
export type PreviewAnnotation = {
  lineNumber: 1;
  metadata: { kind: "rich-preview"; preview: PreviewKind; path: string; previousPath?: string };
};

/** The code view's item for a previewed file: one blank line and the preview under it. */
export type PreviewItem = {
  id: string;
  type: "file";
  file: { name: string; contents: string; cacheKey: string; lang: "text" };
  annotations: PreviewAnnotation[];
  collapsed?: boolean;
  version?: number;
};

const previewItems = new WeakMap<DiffItem, PreviewItem>();

// The Markdown renderer (and its lexer) loads with the first rendered Markdown file, not with
// the diff page: scripts/check-webviews-diff-budget.mjs keeps the page's eager JS in budget.
const MarkdownPreview = lazy(() => import("./MarkdownPreview").then((module) => ({ default: module.MarkdownPreview })));

/** An SVG is text too: its diff stays (with hunk Stage and Revert) unless Rich preview is on. */
const isTextImage = (path: string) => path.toLowerCase().endsWith(".svg");

/**
 * The preview item for `item`, or null when it shows its diff: images always preview, Markdown
 * and SVG only with Rich preview on, and only where the host can read the file's sides.
 */
export function previewItemFor(
  item: DiffItem,
  options: { richPreview: boolean; canRead: boolean },
): PreviewItem | null {
  if (!options.canRead) return null;
  const fileDiff = item.fileDiff ?? {};
  const path = typeof fileDiff.name === "string" ? fileDiff.name : "";
  const preview = path ? previewKindOf(path) : undefined;
  if (!preview || ((preview === "markdown" || isTextImage(path)) && !options.richPreview)) return null;
  const known = previewItems.get(item);
  if (known && known.collapsed === item.collapsed) return known;
  const previousPath =
    typeof fileDiff.prevName === "string" && fileDiff.prevName !== path ? fileDiff.prevName : undefined;
  const made: PreviewItem = {
    id: item.id,
    type: "file",
    file: { name: path, contents: " ", cacheKey: `${item.id}:preview`, lang: "text" },
    annotations: [
      { lineNumber: 1, metadata: { kind: "rich-preview", preview, path, ...(previousPath ? { previousPath } : {}) } },
    ],
    ...(item.collapsed !== undefined ? { collapsed: item.collapsed } : {}),
    ...(item.version !== undefined ? { version: item.version } : {}),
  };
  previewItems.set(item, made);
  return made;
}

export function isPreviewAnnotation(annotation: unknown): annotation is PreviewAnnotation {
  const metadata = (annotation as { metadata?: { kind?: unknown } } | null)?.metadata;
  return metadata?.kind === "rich-preview";
}

/** What the previews loaded in one session: a preview scrolled away and back asks the host once. */
export type PreviewCache = Map<string, Promise<FileContents>>;

type Loaded = { state: "loading" } | { state: "failed" } | { state: "loaded"; contents: FileContents };

export function InlinePreview({
  annotation,
  load,
  cache,
  label,
}: {
  annotation: PreviewAnnotation;
  load: FileContentsLoader;
  cache: PreviewCache;
  label: DiffViewerLabelResolver;
}) {
  const { preview, path, previousPath } = annotation.metadata;
  const [loaded, setLoaded] = useState<Loaded>({ state: "loading" });
  useEffect(() => {
    let current = true;
    const encoding = previewEncodingOf(preview);
    const key = `${path}\u0000${previousPath ?? ""}\u0000${encoding}`;
    let request = cache.get(key);
    if (!request) {
      request = load({ path, ...(previousPath ? { previousPath } : {}), encoding });
      cache.set(key, request);
      // A failed read is asked again next time.
      request.catch(() => cache.delete(key));
    }
    request.then(
      (contents) => current && setLoaded({ state: "loaded", contents }),
      () => current && setLoaded({ state: "failed" }),
    );
    return () => {
      current = false;
    };
  }, [cache, load, path, preview, previousPath]);

  const status = (text: string) => (
    <div className="inline-preview">
      <p className="rich-preview-status">{text}</p>
    </div>
  );
  if (loaded.state === "loading") return status(label("previewLoading"));
  if (loaded.state === "failed") return status(label("previewFailed"));
  const { contents } = loaded;
  if (contents.tooLarge) return status(label("previewTooLarge"));
  if (preview === "markdown") {
    // The new version; a deleted file shows what it was.
    const text = markdownText(contents.new ?? contents.old);
    return text === undefined ? (
      status(label("previewNoFile"))
    ) : (
      <Suspense fallback={status(label("previewLoading"))}>
        <div className="inline-preview">
          <MarkdownPreview source={text} />
        </div>
      </Suspense>
    );
  }
  const name = path.slice(path.lastIndexOf("/") + 1);
  const sides = [
    { key: "old", title: label("previewBefore"), url: imageDataURL(previousPath ?? path, contents.old) },
    { key: "new", title: label("previewAfter"), url: imageDataURL(path, contents.new) },
  ];
  return (
    <div className="inline-preview">
      <div className="rich-preview-images">
        {sides.map((side) => (
          <figure key={side.key} className="rich-preview-image" data-side={side.key}>
            {side.url ? (
              <img src={side.url} alt={`${side.title}: ${name}`} />
            ) : (
              <span className="rich-preview-status">{label("previewNoFile")}</span>
            )}
          </figure>
        ))}
      </div>
    </div>
  );
}
