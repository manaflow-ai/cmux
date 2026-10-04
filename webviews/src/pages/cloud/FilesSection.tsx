// The Files section of the selected machine (files.ts). Nothing is read until Browse. Folders open on
// click; a file click previews a small text file, which Edit turns into a field that Save writes back.
// Delete, Upload and Download go to the host (native confirmation or file panel); the page never
// calls `fs.remove`, `file.push` or `file.pull` itself.
import { useState } from "react";
import { formatBytes, plainKeys, type SectionProps } from "./sectionParts";
import { joinPath } from "./files";
import { CloudOps } from "./ops";
import { format, L } from "./strings";

function Preview({ store, detail, strings }: Pick<SectionProps, "store" | "detail" | "strings">) {
  const { t } = strings;
  const preview = detail.files?.preview;
  const [draft, setDraft] = useState<string | null>(null);
  if (!preview) return null;
  const body = () => {
    if (preview.tooLarge)
      return <p className="cloud-muted">{format(t(L.filesTooLarge), { size: formatBytes(preview.size, strings) })}</p>;
    if (preview.binary) return <p className="cloud-muted">{t(L.filesBinary)}</p>;
    if (preview.unread) return <p className="cloud-muted">{t(L.filesNoPreview)}</p>;
    if (draft !== null)
      return (
        <textarea
          className="cloud-input cloud-file-editor cloud-mono"
          aria-label={preview.path}
          value={draft}
          onChange={(event) => setDraft(event.target.value)}
        />
      );
    return <pre className="cloud-file-preview cloud-mono">{preview.text}</pre>;
  };
  const save = () => {
    if (draft === null) return;
    // The draft stays until the write succeeds, so a failed or refused save loses no text.
    void store.files.save(preview.path, draft).then((saved) => saved && setDraft(null));
  };
  return (
    <div className="cloud-file-view">
      <div className="cloud-subsection-header">
        <span className="cloud-item-title cloud-mono">{preview.path}</span>
        <span className="cloud-item-actions">
          {preview.text !== undefined && draft === null && (
            <button
              type="button"
              className="cloud-link-button cloud-file-edit"
              onClick={() => setDraft(preview.text ?? "")}
            >
              {t(L.filesEdit)}
            </button>
          )}
          {draft !== null && (
            <>
              <button type="button" className="cloud-link-button" onClick={() => setDraft(null)}>
                {t(L.cancel)}
              </button>
              <button type="button" className="cloud-link-button cloud-file-save" onClick={save}>
                {t(L.save)}
              </button>
            </>
          )}
          {draft === null && (
            <button type="button" className="cloud-link-button" onClick={() => store.files.closePreview()}>
              {t(L.filesClosePreview)}
            </button>
          )}
        </span>
      </div>
      {body()}
    </div>
  );
}

function NewFolder({ store, t }: { store: SectionProps["store"]; t: (key: string) => string }) {
  const [name, setName] = useState("");
  const submit = () => {
    if (!name.trim()) return;
    void store.files.mkdir(name);
    setName("");
  };
  return (
    <span className="cloud-inline-form">
      <input
        className="cloud-input cloud-folder-name"
        placeholder={t(L.filesNewFolder)}
        aria-label={t(L.filesNewFolder)}
        value={name}
        onChange={(event) => setName(event.target.value)}
        onKeyDown={plainKeys(submit)}
      />
      <button
        type="button"
        className="cloud-button cloud-folder-add"
        aria-label={t(L.filesNewFolder)}
        aria-disabled={!name.trim()}
        onClick={submit}
      >
        +
      </button>
    </span>
  );
}

export function FilesSection({ store, detail, unavailable, strings }: Omit<SectionProps, "machine">) {
  const { t } = strings;
  const files = detail.files;
  const header = (
    <div className="cloud-subsection-header">
      <h3 className="cloud-subsection-title">{t(L.files)}</h3>
      {!files && !unavailable.includes(CloudOps.fsList) && (
        <button type="button" className="cloud-link-button cloud-files-browse" onClick={() => void store.files.open()}>
          {t(L.filesBrowse)}
        </button>
      )}
    </div>
  );
  if (unavailable.includes(CloudOps.fsList))
    return (
      <>
        {header}
        <p className="cloud-muted cloud-unavailable">{t(L.unavailable)}</p>
      </>
    );
  if (!files) return header;
  return (
    <>
      {header}
      <div className="cloud-files-bar">
        <button
          type="button"
          className="cloud-link-button cloud-files-up"
          disabled={files.path === "/"}
          onClick={() => void store.files.up()}
        >
          {t(L.filesUp)}
        </button>
        <code className="cloud-mono cloud-files-path">{files.path}</code>
        <NewFolder store={store} t={t} />
        {!unavailable.includes(CloudOps.filePush) && (
          <button
            type="button"
            className="cloud-link-button cloud-files-upload"
            onClick={() => void store.files.push()}
          >
            {t(L.filesUpload)}
          </button>
        )}
      </div>
      {files.entries?.length ? (
        <ul className="cloud-items cloud-files">
          {files.entries.map((entry) => {
            const path = entry.path ?? joinPath(files.path, entry.name ?? "");
            const folder = entry.kind === "directory";
            return (
              <li key={path} className={`cloud-item cloud-file kind-${entry.kind}`}>
                <button
                  type="button"
                  className="cloud-link-button cloud-file-name cloud-mono"
                  onClick={() => void (folder ? store.files.open(path) : store.files.preview(path))}
                >
                  {entry.name ?? path}
                </button>
                <span className="cloud-item-detail">
                  {folder ? t(L.filesFolder) : entry.size != null ? formatBytes(entry.size, strings) : ""}
                </span>
                <span className="cloud-item-actions">
                  {entry.kind === "file" && !unavailable.includes(CloudOps.filePull) && (
                    <button
                      type="button"
                      className="cloud-link-button cloud-file-download"
                      onClick={() => void store.files.pull(path)}
                    >
                      {t(L.filesDownload)}
                    </button>
                  )}
                  {!unavailable.includes(CloudOps.fsRemove) && (
                    <button
                      type="button"
                      className="cloud-link-button destructive cloud-file-remove"
                      onClick={() => void store.files.remove(path)}
                    >
                      {t(L.delete)}
                    </button>
                  )}
                </span>
              </li>
            );
          })}
        </ul>
      ) : (
        <p className="cloud-muted">{files.loading ? t(L.loading) : t(L.filesEmpty)}</p>
      )}
      <Preview key={files.preview?.path} store={store} detail={detail} strings={strings} />
    </>
  );
}
