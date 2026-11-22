// The Files section of the selected machine (files.ts). Nothing is read until Browse. Folders open on
// click; a file click previews a small text file, which Edit turns into a field that Save writes back.
// Delete, Upload and Download go to the host (native confirmation or file panel); the page never
// calls `fs.remove`, `file.push` or `file.pull` itself. A push or pull shows as a transfer row that
// is running until its `file.transfer.changed` event; a busy refusal shows a message with Retry. A
// machine whose daemon has no file ops yet (`fs-v1`) shows "Not available yet" for that machine.
import { useState } from "react";
import { formatBytes, plainKeys, type SectionProps } from "./sectionParts";
import { joinPath } from "./files";
import { CloudOps } from "./ops";
import { format, L } from "./strings";
import type { FileTransfer } from "./transfers";

const TRANSFER_LABEL = {
  running: L.transferRunning,
  done: L.transferDone,
  failed: L.transferFailed,
  cancelled: L.transferCancelled,
} as const;

function Transfers({ transfers, strings }: { transfers: readonly FileTransfer[]; strings: SectionProps["strings"] }) {
  const { t } = strings;
  if (!transfers.length) return null;
  return (
    <>
      <h4 className="cloud-subsection-title">{t(L.transfers)}</h4>
      <ul className="cloud-items cloud-transfers">
        {transfers.map((transfer) => (
          <li key={transfer.transfer} className={`cloud-item cloud-transfer kind-${transfer.direction}`}>
            <span className="cloud-item-title cloud-mono">{transfer.path}</span>
            <span className="cloud-item-detail">
              {transfer.state === "done" && transfer.bytes != null ? formatBytes(transfer.bytes, strings) : ""}
            </span>
            <span className={`cloud-transfer-state state-${transfer.state}`} title={transfer.error}>
              {t(TRANSFER_LABEL[transfer.state])}
            </span>
          </li>
        ))}
      </ul>
    </>
  );
}

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

export function FilesSection({
  store,
  detail,
  unavailable,
  transfers,
  strings,
}: Omit<SectionProps, "machine"> & { transfers: readonly FileTransfer[] }) {
  const { t } = strings;
  const files = detail.files;
  const off = unavailable.includes(CloudOps.fsList) || !!files?.unavailable;
  const rows = <Transfers transfers={transfers.filter((item) => item.machine === detail.machine)} strings={strings} />;
  const header = (
    <div className="cloud-subsection-header">
      <h3 className="cloud-subsection-title">{t(L.files)}</h3>
      {!files && !off && (
        <button type="button" className="cloud-link-button cloud-files-browse" onClick={() => void store.files.open()}>
          {t(L.filesBrowse)}
        </button>
      )}
    </div>
  );
  if (off)
    return (
      <>
        {header}
        <p className="cloud-muted cloud-unavailable">{t(L.unavailable)}</p>
      </>
    );
  if (!files)
    return (
      <>
        {header}
        {rows}
      </>
    );
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
      {files.busy && (
        <p className="cloud-muted cloud-transfer-busy">
          {t(L.transferBusy)}{" "}
          <button
            type="button"
            className="cloud-link-button cloud-transfer-retry"
            onClick={() => void store.files.retryTransfer()}
          >
            {t(L.retry)}
          </button>
        </p>
      )}
      {rows}
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
