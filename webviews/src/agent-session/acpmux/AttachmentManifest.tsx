import { useContext, useEffect, useRef, useState } from "react";
import { Dialog } from "../../ui/Dialog";
import { keyedIconProps } from "../../ui/DialogButton";
import { attachmentSource } from "./attachments";
import {
  attachmentManifestPage,
  type AttachmentManifestPage,
  type ManifestAttachment,
  type UploadManifest,
} from "./attachmentManifest";
import { attachmentPath, FileAttachmentBody, type FileAttachmentInfo } from "./FileAttachment";
import { useSourceLabel } from "./composer/SourceBadge";
import { Close } from "./conversation/icons";
import { TurnActionsContext } from "./conversation/turnActions";
import { useT } from "./i18n";

/** One page lives only while the viewer is open; back keeps byte cursors, never file contents. */
export function AttachmentManifest({ file }: { file: FileAttachmentInfo }) {
  const t = useT();
  const { attachmentManifestSession: sessionId } = useContext(TurnActionsContext);
  const [opened, setOpened] = useState<string>();
  useEffect(() => {
    setOpened(undefined);
  }, [sessionId, file.uploadManifest]);
  return (
    <>
      <button
        type="button"
        className="acpmux-manifest-trigger"
        aria-label={t("attachment.manifest.open", { name: file.name })}
        aria-haspopup="dialog"
        onClick={() => setOpened(sessionId ?? "")}
      >
        <FileAttachmentBody file={file} />
      </button>
      {opened !== undefined && opened === (sessionId ?? "") && file.uploadManifest && (
        <Dialog
          open
          onOpenChange={(open) => {
            if (!open) setOpened(undefined);
          }}
          label={file.name}
          className="acpmux-pdf-viewer ui-glass acpmux-manifest-dialog"
        >
          <div className="acpmux-image-viewer-bar">
            <span className="acpmux-image-viewer-title">{file.name}</span>
            <button
              type="button"
              className="acpmux-image-viewer-action"
              {...keyedIconProps(t("image.close"), "escape")}
              onClick={() => setOpened(undefined)}
            >
              <Close />
            </button>
          </div>
          <AttachmentManifestContents key={`${sessionId}:${file.uploadManifest.uri}`} manifest={file.uploadManifest} />
        </Dialog>
      )}
    </>
  );
}

export function AttachmentManifestContents({ manifest }: { manifest: UploadManifest }) {
  const t = useT();
  const { attachmentManifestSession: sessionId, attachmentManifestPage: read } = useContext(TurnActionsContext);
  const [{ offset, previous }, navigate] = useState({ offset: 0, previous: [] as number[] });
  const [retry, setRetry] = useState(0);
  const [result, setResult] = useState<{ page?: AttachmentManifestPage; error?: true }>({});
  const list = useRef<HTMLOListElement>(null);
  useEffect(() => {
    let active = true;
    setResult({});
    if (!read || !sessionId) {
      setResult({ error: true });
      return;
    }
    void read(sessionId, manifest, offset)
      .then((value) => attachmentManifestPage(value, offset))
      .then(
        (page) => {
          if (!active) return;
          setResult({ page });
          if (list.current) list.current.scrollTop = 0;
        },
        () => {
          if (active) setResult({ error: true });
        },
      );
    // Closing, paging, or changing chats invalidates the answer. No automatic page prefetch/cache.
    return () => {
      active = false;
    };
  }, [manifest, sessionId, read, offset, retry]);
  const { page, error } = result;
  return (
    <div className="acpmux-manifest-contents">
      <ol
        ref={list}
        className="acpmux-manifest-list"
        aria-label={t("composer.attachments")}
        aria-busy={!page && !error}
      >
        {page?.attachments.map((entry) => (
          <ManifestEntry key={entry.blockIndex} entry={entry} />
        ))}
      </ol>
      <div className="acpmux-manifest-status" role="status">
        {error
          ? t("attachment.manifest.failed")
          : !page
            ? t("attachment.manifest.loading")
            : t("attachment.manifest.page", { page: previous.length + 1 })}
        {error && (
          <button type="button" onClick={() => setRetry((value) => value + 1)}>
            {t("host.retry")}
          </button>
        )}
      </div>
      <nav className="acpmux-manifest-pages" aria-label={t("attachment.manifest.pages")}>
        <button
          type="button"
          disabled={!previous.length}
          onClick={() => navigate({ offset: previous.at(-1)!, previous: previous.slice(0, -1) })}
        >
          {t("find.previous")}
        </button>
        <button
          type="button"
          disabled={!page?.hasMore}
          onClick={() => {
            if (page?.hasMore) navigate({ offset: page.manifestOffset, previous: [...previous, offset] });
          }}
        >
          {t("find.next")}
        </button>
      </nav>
    </div>
  );
}

function ManifestEntry({ entry }: { entry: ManifestAttachment }) {
  const display = entry.displayPart;
  const block = entry.block;
  const source = attachmentSource(display?.source);
  const sourceLabel = useSourceLabel(source);
  const file: FileAttachmentInfo = {
    name: typeof display?.name === "string" ? display.name : typeof block.name === "string" ? block.name : block.uri,
    mimeType: typeof block.mimeType === "string" ? block.mimeType : undefined,
    size: typeof display?.size === "number" ? display.size : typeof block.size === "number" ? block.size : undefined,
    path: attachmentPath(block.uri) ?? block.uri,
    source,
  };
  return (
    <li data-block-index={entry.blockIndex} className="acpmux-manifest-row">
      <span className="acpmux-manifest-index">{entry.blockIndex + 1}</span>
      <FileAttachmentBody file={file} />
      {sourceLabel && <span className="acpmux-manifest-source">{sourceLabel}</span>}
    </li>
  );
}
