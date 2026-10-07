import { useEffect, useRef, useState, type KeyboardEvent } from "react";
import { Combobox } from "../../ui/Combobox";
import { Dialog } from "../../ui/Dialog";
import { KeyboardScope } from "../../ui/KeyboardScope";
import { useT } from "./i18n";
import {
  directoryName,
  projectDirectoryHost,
  type ProjectDirectory,
  type ProjectDirectoryHost,
} from "./projectDirectory";
import "./addProject.css";

type Step = "environment" | "source" | "directory";
export type AddProjectPanelProps = {
  host?: ProjectDirectoryHost;
  localName?: string;
  peers?: string[];
  /** Existing native folder chooser, retained as a fallback for older hosts. */
  onBrowse?(): Promise<string | undefined> | string | undefined | void;
  onPick(path: string): void;
  onClose(): void;
};

/** One command panel: its header, input and footer stay in place while its list changes. */
export function AddProjectPanel({
  host = projectDirectoryHost,
  localName,
  peers = [],
  onBrowse,
  onPick,
  onClose,
}: AddProjectPanelProps) {
  const t = useT();
  const [step, setStep] = useState<Step>("environment");
  const [query, setQuery] = useState("");
  const [requested, setRequested] = useState("~");
  const [directory, setDirectory] = useState<ProjectDirectory>();
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string>();
  const [revealError, setRevealError] = useState<string>();
  const [retry, setRetry] = useState(0);
  const input = useRef<HTMLInputElement>(null);
  const request = useRef(0);
  const fallbackToNative = () => {
    void Promise.resolve(onBrowse?.()).then((path) => {
      if (path) onPick(path);
      else if (path === undefined) onClose();
    });
  };
  useEffect(() => {
    input.current?.focus();
  }, [step, directory?.path]);
  useEffect(() => {
    if (step !== "directory") return;
    const id = ++request.current;
    let live = true;
    setLoading(true);
    setError(undefined);
    setRevealError(undefined);
    if (!host.list) return;
    void host
      .list(requested)
      .then((result) => {
        if (live && request.current === id) {
          setDirectory(result);
          setQuery("");
        }
      })
      .catch((failure: unknown) => {
        const code = (failure as { code?: unknown })?.code;
        if (live && (code === "unsupported" || code === "native.invalid_request") && onBrowse) {
          fallbackToNative();
          return;
        }
        if (live && request.current === id) setError(failure instanceof Error ? failure.message : String(failure));
      })
      .finally(() => {
        if (live && request.current === id) setLoading(false);
      });
    return () => {
      live = false;
      setLoading(false);
    };
  }, [host, requested, step, retry]);

  const back = () => {
    setStep(step === "directory" ? "source" : "environment");
    setQuery("");
    setError(undefined);
    setRevealError(undefined);
  };
  const browse = (path: string) => {
    setRequested(path);
    setRetry((value) => value + 1);
  };
  const add = () => {
    if (directory && !loading && !error) onPick(directory.path);
  };
  const choices =
    step === "environment"
      ? [
          { id: "local", label: localName || t("composer.thisMac"), disabled: false },
          ...peers.map((peer) => ({ id: `peer:${peer}`, label: peer, disabled: true })),
        ]
      : step === "source"
        ? [
            { id: "folder", label: t("project.localFolder"), disabled: false },
            { id: "new", label: t("project.new"), disabled: false },
            { id: "git", label: t("project.gitURL"), disabled: true },
            { id: "github", label: t("project.github"), disabled: true },
            { id: "other", label: t("project.otherSources"), disabled: true },
          ]
        : (loading || error ? [] : (directory?.directories ?? [])).map((path) => ({
            id: path,
            label: directoryName(path),
            disabled: false,
          }));
  const shown = choices.filter((choice) => choice.label.toLocaleLowerCase().includes(query.trim().toLocaleLowerCase()));
  const chooseFolder = () => {
    if (host.list) {
      setStep("directory");
      setQuery("");
      return;
    }
    void Promise.resolve(onBrowse?.()).then((path) => {
      if (path) onPick(path);
      else if (path === undefined) onClose();
    });
  };
  const select = (id: string) => {
    const choice = choices.find((item) => item.id === id);
    if (choice?.disabled) return;
    if (step === "environment" && choice?.id === "local") {
      setStep("source");
      setQuery("");
    } else if (step === "source" && (choice?.id === "folder" || choice?.id === "new")) chooseFolder();
    else if (step === "directory") {
      if (choice) browse(choice.id);
      else if (id.trim())
        browse(id.startsWith("/") || id.startsWith("~") ? id.trim() : `${directory?.path ?? "~"}/${id.trim()}`);
    }
  };
  const command = (event: KeyboardEvent<HTMLDivElement>) => {
    if ((event.metaKey || event.ctrlKey) && event.key === "Enter" && step === "directory") {
      event.preventDefault();
      event.stopPropagation();
      add();
    } else if (event.altKey && event.key === "ArrowLeft" && step !== "environment") {
      event.preventDefault();
      event.stopPropagation();
      back();
    }
  };
  const path = directory?.path ?? requested;
  const title =
    step === "environment" ? t("project.environment") : step === "source" ? t("project.add") : t("project.choose");
  return (
    <KeyboardScope handleKeyDown={command}>
      <div className="acpmux-add-project" data-add-project-step={step}>
        <div className="acpmux-add-project-heading">
          <button type="button" onClick={back} disabled={step === "environment"} aria-label={t("project.back")}>
            ←
          </button>
          <strong>{title}</strong>
          <button type="button" onClick={onClose} aria-label={t("project.close")}>
            ×
          </button>
        </div>
        <div className="acpmux-add-project-path">
          {step === "directory" ? (
            <>
              <button
                type="button"
                disabled={!directory?.parent || loading}
                onClick={() => browse(directory!.parent!)}
                aria-label={t("project.back")}
              >
                ↑
              </button>
              <span title={path}>
                {directory && path.startsWith(`${directory.home}/`)
                  ? `~/${path.slice(directory.home.length + 1)}`
                  : directory && path === directory.home
                    ? "~"
                    : path}
              </span>
            </>
          ) : (
            <span>{step === "environment" ? t("project.add") : localName || t("composer.thisMac")}</span>
          )}
        </div>
        <Combobox
          key={`${step}:${directory?.path ?? ""}`}
          inputRef={input}
          suggestions={shown.map((choice) => choice.id)}
          onQuery={setQuery}
          onSubmit={select}
          onCancel={onClose}
          cancelOnBlur={false}
          isItemDisabled={(id) => choices.find((choice) => choice.id === id)?.disabled ?? step !== "directory"}
          autoHighlight
          rootClassName="acpmux-add-project-combobox"
          label={step === "directory" ? t("project.path") : title}
          placeholder={t("project.filter")}
          inputClassName="acpmux-add-project-input"
          listClassName="acpmux-add-project-list"
          itemClassName="acpmux-add-project-item"
          renderItem={(id) => {
            const choice = choices.find((item) => item.id === id)!;
            return (
              <>
                <FolderIcon />
                <span className="acpmux-add-project-label">{choice.label}</span>
                {choice.disabled && <span className="acpmux-add-project-tag">{t("project.setupRequired")}</span>}
              </>
            );
          }}
          inline
        />
        <output className="acpmux-add-project-status">
          {loading ? (
            t("project.loading")
          ) : error ? (
            <>
              <span>{error}</span>
              <button type="button" onClick={() => setRetry((value) => value + 1)}>
                {t("project.retry")}
              </button>
            </>
          ) : revealError ? (
            <span>{revealError}</span>
          ) : shown.length === 0 ? (
            t("project.emptyFolder")
          ) : null}
        </output>
        <div className="acpmux-add-project-actions">
          {step === "directory" && (
            <>
              <button
                type="button"
                disabled={!directory || loading || !!error || !host.reveal}
                onClick={() => {
                  if (directory && host.reveal) {
                    setRevealError(undefined);
                    void host.reveal(directory.path).catch((failure: unknown) => {
                      setRevealError(failure instanceof Error ? failure.message : String(failure));
                    });
                  }
                }}
              >
                {t("project.openFinder")}
              </button>
              <button
                type="button"
                className="acpmux-add-project-submit"
                disabled={!directory || loading || !!error}
                onClick={add}
              >
                {t("project.addFolder")} <kbd>⌘↵</kbd>
              </button>
            </>
          )}
        </div>
        <div className="acpmux-add-project-footer">
          <span>
            <kbd>↑↓</kbd> {t("project.navigate")}
          </span>
          <span>
            <kbd>↵</kbd> {t("project.select")}
          </span>
          <span>
            <kbd>⌥←</kbd> {t("project.back")}
          </span>
          <span>
            <kbd>{t("project.escape")}</kbd> {t("project.close")}
          </span>
        </div>
      </div>
    </KeyboardScope>
  );
}

export function AddProjectDialog({ open, ...props }: AddProjectPanelProps & { open: boolean }) {
  const t = useT();
  if (!open) return null;
  return (
    <Dialog
      open={open}
      onOpenChange={(next) => {
        if (!next) props.onClose();
      }}
      label={t("project.add")}
      className="acpmux-add-project-dialog"
    >
      <AddProjectPanel {...props} />
    </Dialog>
  );
}

function FolderIcon() {
  return (
    <svg
      width="16"
      height="16"
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.25"
      aria-hidden="true"
    >
      <path d="M2 4h4l1.5 2H14v7H2z" />
    </svg>
  );
}
