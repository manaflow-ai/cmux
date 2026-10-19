// A file from the chat (a path chip, a changed file's Open in tab) in the chat's viewer, beside the
// transcript (labs `chatViewer`, Lucas 2026-10-19). It takes the changes view's slot and layout, so
// Files and linked files share one viewer and the chat stays on screen; the app's file tab is one click
// away (Open in tab).
import type { KeyboardEvent } from "react";
import { useEffect, useRef } from "react";
import { useT } from "./i18n";
import { Code, OpenTab } from "./changeIcons";
import { CodeBlock } from "./conversation/CodeBlock";
import { Icon } from "./icons/Icon";
import { isHighlighted } from "./shikiLanguages";

/// What `link.readPath` returned for a text file, and the session it was opened in.
export type ViewedFile = {
  path: string;
  text: string;
  bytes: number;
  truncated: boolean;
  sessionId?: string;
};

const NAMED: Record<string, string> = { makefile: "make", dockerfile: "dockerfile" };
const EXTENSIONS: Record<string, string> = { rs: "rust", kt: "kotlin", kts: "kotlin", h: "c", htm: "html" };

/// The highlighter language for `path`: its extension when the bundle highlights it, else text.
export function fileLanguage(path: string): string {
  const name = path.split("/").pop()?.toLowerCase() ?? "";
  const named = NAMED[name];
  if (named) return named;
  const extension = name.includes(".") ? name.slice(name.lastIndexOf(".") + 1) : "";
  const lang = EXTENSIONS[extension] ?? extension;
  return lang && isHighlighted(lang) ? lang : "text";
}

export function FileViewer({
  file,
  onClose,
  onOpenFile,
}: {
  file: ViewedFile;
  /// The X and Escape: back to the Files list it was opened from, else out of the viewer.
  onClose(): void;
  /// The app's own file tab or the editor: leaving the chat is the reader's explicit choice.
  onOpenFile(path: string, where: "tab" | "editor"): void;
}) {
  const t = useT();
  const close = useRef<HTMLButtonElement>(null);
  const name = file.path.split("/").pop() || file.path;
  // A new file moves focus into the viewer, as opening the changes view does.
  useEffect(() => close.current?.focus({ preventScroll: true }), [file.path]);
  const onKeyDown = (event: KeyboardEvent) => {
    if (event.key !== "Escape" || event.defaultPrevented) return;
    event.preventDefault();
    onClose();
  };
  return (
    // oxlint-disable-next-line jsx-a11y/no-noninteractive-element-interactions -- Escape closes the viewer from any control in it.
    <section className="acpmux-diff-panel acpmux-file-viewer" aria-label={name} onKeyDown={onKeyDown}>
      <header className="acpmux-diff-header">
        {/* tooltip-allow: the label shows the file's name; the tooltip reveals its full path, like FolderPopover */}
        <span className="acpmux-file-viewer-name" title={file.path}>
          {name}
        </span>
        <div className="acpmux-diff-tools" role="toolbar" aria-label={name}>
          <button
            type="button"
            className="acpmux-diff-tool"
            aria-label={t("changes.openPathInTab", { path: name })}
            title={t("changes.openInTab")}
            onClick={() => onOpenFile(file.path, "tab")}
          >
            <OpenTab />
          </button>
          <button
            type="button"
            className="acpmux-diff-tool"
            aria-label={t("changes.openPathInEditor", { path: name })}
            title={t("changes.openInEditor")}
            onClick={() => onOpenFile(file.path, "editor")}
          >
            <Code />
          </button>
          <button
            ref={close}
            type="button"
            className="acpmux-diff-tool"
            aria-label={t("image.close")}
            title={t("image.close")}
            onClick={onClose}
          >
            <Icon name="action.close" size={12} />
          </button>
        </div>
      </header>
      <div className="acpmux-file-viewer-body">
        <CodeBlock code={file.text} lang={fileLanguage(file.path)} label={file.path} />
        {file.truncated && (
          <p className="acpmux-file-viewer-note">
            {t("inspector.truncated", { shown: file.text.length, total: file.bytes })}
          </p>
        )}
      </div>
    </section>
  );
}
