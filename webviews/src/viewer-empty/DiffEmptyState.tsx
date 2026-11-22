// The diff page's empty state: no repository yet. The user picks a recent repository, chooses a
// folder (the host's picker) or drops one; then picks what to compare (the source menu's sources)
// and opens it. `cmux.diff.open` answers the page config, which the boot path renders.
import { useRef, useState } from "react";
import { ChoiceGroup } from "../ui/ChoiceGroup";
import type { DiffSource } from "../diff/generated/protocol";
import type { DiffViewerLabelResolver } from "../labels";
import { isPageError, type PageClient } from "../pages/shared/pageClient";
import type { Strings } from "../pages/shared/i18n";
import { sourceMenuModel, type SourceMenuEntry } from "../toolbar-model";
import type { DroppedItem } from "./drop";
import { EmptyState, RecentList, TailPath } from "./EmptyState";
import { EmptyIcon } from "./icons";
import {
  DIFF_CHOOSE_FOLDER_OP,
  DIFF_NOT_A_REPO,
  DIFF_OPEN_OP,
  DIFF_RECENTS_OP,
  baseName,
  parseChosenPath,
  parseRecents,
  tildePath,
  type EmptySourceKind,
  type RecentItem,
} from "./ops";
import { parentPath } from "./pickerModel";
import { E } from "./strings";

/** The sources the empty state offers, in order; ids of the source menu (toolbar-model.ts). */
export const EMPTY_SOURCE_KINDS: readonly EmptySourceKind[] = ["branch", "uncommitted", "staged", "unstaged"];

const SOURCE_HELP: Record<EmptySourceKind, string> = {
  branch: E.sourceBranchHelp,
  uncommitted: E.sourceUncommittedHelp,
  staged: E.sourceStagedHelp,
  unstaged: E.sourceUnstagedHelp,
};

export interface EmptySourceOption {
  kind: EmptySourceKind;
  entry: SourceMenuEntry;
  source: DiffSource;
}

/** The source choices for `repoRoot`, built by the toolbar's source menu model. */
export function emptySourceOptions(repoRoot: string): EmptySourceOption[] {
  const model = sourceMenuModel({
    sourceOptions: [],
    repoRoot,
    activeSource: null,
    typedTransport: true,
    isValidSource: (value): value is DiffSource => value != null,
  });
  const entries = new Map(model.sections.flat().map((entry) => [entry.id, entry]));
  return EMPTY_SOURCE_KINDS.flatMap((kind) => {
    const entry = entries.get(kind);
    const target = entry?.target;
    return entry && target?.kind === "session" ? [{ kind, entry, source: target.source }] : [];
  });
}

export interface DiffEmptyStateProps {
  client: PageClient;
  strings: Strings;
  label: DiffViewerLabelResolver;
  /** The page config `cmux.diff.open` answered. */
  onOpened(config: unknown): void;
  now?: number;
}

type Step = { kind: "list" } | { kind: "source"; path: string; source: EmptySourceKind };

export function DiffEmptyState({ client, strings, label, onOpened, now }: DiffEmptyStateProps) {
  const { t } = strings;
  const [recents, setRecents] = useState<RecentItem[] | null>(null);
  const [home, setHome] = useState<string | null>(null);
  const [step, setStep] = useState<Step>({ kind: "list" });
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const loaded = useRef(false);

  const load = async () => {
    try {
      const value = await client.call<unknown>(DIFF_RECENTS_OP, {});
      setRecents(parseRecents(value));
      const reported = (value as { home?: unknown } | null)?.home;
      setHome(typeof reported === "string" ? reported : null);
    } catch {
      setRecents([]);
    }
  };
  const mountRef = (element: HTMLDivElement | null) => {
    if (!element || loaded.current) return;
    loaded.current = true;
    void load();
  };

  const remembered = (path: string): EmptySourceKind => recents?.find((item) => item.path === path)?.source ?? "branch";
  const pick = (path: string, source: EmptySourceKind = remembered(path)) => {
    setError(null);
    setStep({ kind: "source", path, source });
  };
  const chooseFolder = async () => {
    setError(null);
    const start = recents?.[0] ? parentPath(recents[0].path) : undefined;
    let value: unknown;
    try {
      value = await client.call<unknown>(DIFF_CHOOSE_FOLDER_OP, start ? { start } : {});
    } catch (failure) {
      console.warn("cmux diff chooseFolder failed", failure);
      return;
    }
    const path = parseChosenPath(value);
    if (path) pick(path);
  };
  const open = async (path: string, source: DiffSource) => {
    setBusy(true);
    setError(null);
    try {
      const config = await client.call<unknown>(DIFF_OPEN_OP, { path, source });
      onOpened(config);
    } catch (failure) {
      setBusy(false);
      setError(
        isPageError(failure) && failure.code === DIFF_NOT_A_REPO
          ? strings.format(E.errorNotRepo, baseName(path))
          : strings.format(E.errorOpen, baseName(path)),
      );
    }
  };
  const onDrop = (item: DroppedItem) => {
    if (item.path) pick(item.path);
    else setError(strings.format(E.errorOpen, item.name));
  };

  return (
    <div ref={mountRef} className="ve-root">
      <EmptyState
        kind="diff"
        title={t(E.diffTitle)}
        subtitle={t(E.diffSubtitle)}
        dropText={t(E.dropFolder)}
        onDrop={onDrop}
        error={error}
      >
        {step.kind === "list" ? (
          <>
            <div className="ve-actions">
              <button
                type="button"
                className="ve-button ve-button-primary ve-button-large"
                onClick={() => void chooseFolder()}
              >
                {t(E.diffChoose)}
              </button>
            </div>
            <RecentList
              items={recents}
              home={home}
              icon="repo"
              strings={strings}
              label={t(E.recentReposLabel)}
              emptyText={t(E.recentReposEmpty)}
              now={now}
              onOpen={(item) => pick(item.path, item.source)}
            />
          </>
        ) : (
          <SourceStep
            path={step.path}
            home={home}
            selected={step.source}
            busy={busy}
            strings={strings}
            label={label}
            onSelect={(source) => setStep({ ...step, source })}
            onOpen={(source) => void open(step.path, source)}
            onChange={() => void chooseFolder()}
            onBack={() => {
              setError(null);
              setStep({ kind: "list" });
            }}
          />
        )}
      </EmptyState>
    </div>
  );
}

function SourceStep({
  path,
  home,
  selected,
  busy,
  strings,
  label,
  onSelect,
  onOpen,
  onChange,
  onBack,
}: {
  path: string;
  home: string | null;
  selected: EmptySourceKind;
  busy: boolean;
  strings: Strings;
  label: DiffViewerLabelResolver;
  onSelect(kind: EmptySourceKind): void;
  onOpen(source: DiffSource): void;
  onChange(): void;
  onBack(): void;
}) {
  const { t } = strings;
  const options = emptySourceOptions(path);
  const index = Math.max(
    0,
    options.findIndex((option) => option.kind === selected),
  );
  const current = options[index];
  const focused = useRef(false);
  return (
    <div className="ve-step">
      <div className="ve-chosen">
        <EmptyIcon name="repo" />
        <span className="ve-recent-text">
          <span className="ve-recent-name">{baseName(path)}</span>
          <span className="ve-recent-path">
            <TailPath path={tildePath(path, home)} />
          </span>
        </span>
        <button type="button" className="ve-button ve-button-quiet" onClick={onChange}>
          {t(E.sourceChange)}
        </button>
      </div>
      <h2 className="ve-section-title">{t(E.sourceHeading)}</h2>
      {/* Native radios: arrows move the choice; Return opens it, Escape goes back to the list. */}
      <ChoiceGroup
        className="ve-sources"
        label={t(E.sourceHeading)}
        busy={busy}
        onSubmit={() => current && onOpen(current.source)}
        onCancel={onBack}
      >
        {options.map((option) => {
          const checked = option.kind === current?.kind;
          const title = option.entry.labelKey ? label(option.entry.labelKey) : option.kind;
          return (
            // oxlint-disable-next-line jsx-a11y/label-has-associated-control
            <label
              key={option.kind}
              className="ve-source"
              data-source={option.kind}
              data-checked={checked || undefined}
              onDoubleClick={() => !busy && onOpen(option.source)}
            >
              <input
                ref={
                  checked
                    ? (element) => {
                        if (!element || focused.current) return;
                        focused.current = true;
                        element.focus({ preventScroll: true });
                      }
                    : undefined
                }
                className="ve-radio"
                type="radio"
                name="ve-source"
                value={option.kind}
                checked={checked}
                aria-label={title}
                aria-describedby={`ve-source-help-${option.kind}`}
                onChange={() => onSelect(option.kind)}
              />
              <span className="ve-recent-text">
                <span className="ve-recent-name">{title}</span>
                <span className="ve-recent-path" id={`ve-source-help-${option.kind}`}>
                  {t(SOURCE_HELP[option.kind])}
                </span>
              </span>
            </label>
          );
        })}
      </ChoiceGroup>
      <div className="ve-actions">
        <button type="button" className="ve-button" onClick={onBack} disabled={busy}>
          {t(E.back)}
        </button>
        <button
          type="button"
          className="ve-button ve-button-primary"
          disabled={busy || !current}
          onClick={() => current && onOpen(current.source)}
        >
          {busy ? t(E.opening) : t(E.sourceOpen)}
        </button>
      </div>
    </div>
  );
}
