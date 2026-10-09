// Owns the diff viewer toolbar: the pill, the view options rows, the source and base controls
// and the branch picker payload they read.
import { BranchBasePicker, branchPickerStateKey, type BranchPickerPayload } from "../BranchBasePicker";
import { type DiffItem } from "../diff-stream";
import { Icon, type IconName } from "../icons";
import { type DiffViewerOptions } from "../pierre-options";
import { FloatingToolbar, JumpToFilePalette, SourceMenu, ViewMenuButton } from "../DiffToolbar";
import { diffLineTotals, NO_HOST_CAPABILITIES, overflowMenuItems, sourceMenuModel, toolbarPillButtons, type OverflowMenuItemId, type PillButtonId, type SourceTarget } from "../toolbar-model";
import type { DiffViewerLabelResolver } from "../labels";
import type { DiffViewerConfig } from "../types";
import { type DiffTransport } from "../diff/transport";
import type { DiffSource } from "../diff/generated/protocol";
import { type SelectSessionSource, diffSourceRepoRoot, repoSelectionWithActiveSource, sourceSelectionWithActiveRepo, validDiffSource } from "./session";
import { type AppAction, type AppState, type DiffViewerLayout } from "./state";

export function Toolbar({
  activeSessionSource,
  config,
  label,
  onJump,
  onNavigate,
  onSelectSessionSource,
  pill,
  rememberedBranch,
  state,
  transport,
  visibleItems,
}: {
  activeSessionSource: DiffSource | null;
  config: DiffViewerConfig;
  label: DiffViewerLabelResolver;
  onJump: (itemId: string) => void;
  onNavigate: (url: string) => void;
  onSelectSessionSource: SelectSessionSource;
  /** The floating toolbar pill, at the right end of the bar above the files sidebar. */
  pill: React.ReactNode;
  rememberedBranch: Extract<DiffSource, { kind: "branch" }> | null;
  state: AppState;
  transport: DiffTransport | null;
  visibleItems: DiffItem[];
}) {
  const payload = config.payload ?? {};
  return (
    <header id="toolbar">
      <SourceControls
        activeSessionSource={activeSessionSource}
        items={state.items}
        label={label}
        onNavigate={onNavigate}
        onSelectSessionSource={onSelectSessionSource}
        payload={payload}
        rememberedBranch={rememberedBranch}
        transport={transport}
      >
        <JumpToFilePalette items={visibleItems} label={label} onJump={onJump} />
      </SourceControls>
      {pill}
      <span id="copy-feedback" className="visually-hidden" aria-live="polite">
        {state.copyFeedback}
      </span>
    </header>
  );
}

/**
 * The toolbar pill (top right, above the files sidebar) and its "..." menu: the
 * menu rows the reference viewer has, then the remaining view options.
 */
export function DiffPill({
  dispatch,
  externalURL,
  label,
  onCopyGitApply,
  onReload,
  onSetLayout,
  onSetOption,
  state,
}: {
  dispatch: React.Dispatch<AppAction>;
  externalURL: string | null;
  label: DiffViewerLabelResolver;
  onCopyGitApply: () => void;
  onReload: () => void;
  onSetLayout: (layout: DiffViewerLayout) => void;
  onSetOption: (key: keyof DiffViewerOptions, value: any) => void;
  state: AppState;
}) {
  const onButton = (id: PillButtonId) => {
    switch (id) {
      case "options":
        dispatch({ type: "set-options-open", open: !state.optionsOpen });
        return;
      case "find":
        dispatch(state.findOpen ? { type: "set-find-open", open: false } : { type: "request-find" });
        return;
      case "refresh":
        onReload();
        return;
      case "wrap":
        onSetOption("wordWrap", !state.options.wordWrap);
        return;
      case "expand":
        onSetOption("collapsed", !state.options.collapsed);
        return;
      case "layout":
        onSetLayout(state.options.layout === "split" ? "unified" : "split");
        return;
      case "files":
        dispatch({ type: "set-files-visible", visible: !state.filesVisible });
        return;
    }
  };
  const onMenuItem = (id: OverflowMenuItemId) => {
    switch (id) {
      case "load-full-files":
        onSetOption("expandUnchanged", !state.options.expandUnchanged);
        return;
      case "word-diffs":
        onSetOption("wordDiffs", !state.options.wordDiffs);
        return;
      case "copy-git-apply":
        onCopyGitApply();
        return;
      default:
        // Rich preview, Hide white space and Hide imports have nothing the viewer
        // can apply yet; their rows are unavailable (NO_HOST_CAPABILITIES).
        return;
    }
  };
  return (
    <FloatingToolbar
      buttons={toolbarPillButtons(state)}
      label={label}
      menuItems={overflowMenuItems(state.options, NO_HOST_CAPABILITIES)}
      menuOpen={state.optionsOpen}
      onButton={onButton}
      onCloseMenu={() => dispatch({ type: "set-options-open", open: false })}
      onMenuItem={onMenuItem}
      viewMenu={
        <ViewOptionsMenuRows
          externalURL={externalURL}
          label={label}
          onSetOption={onSetOption}
          onToggleHideViewed={() =>
            dispatch({ type: "set-file-filter", filter: { hideViewed: !state.fileFilter.hideViewed } })
          }
          state={state}
        />
      }
    />
  );
}

/** View options the reference menu does not list, kept under a separator. */
function ViewOptionsMenuRows({
  externalURL,
  label,
  onSetOption,
  onToggleHideViewed,
  state,
}: {
  externalURL: string | null;
  label: DiffViewerLabelResolver;
  onSetOption: (key: keyof DiffViewerOptions, value: any) => void;
  onToggleHideViewed: () => void;
  state: AppState;
}) {
  return (
    <>
      <hr className="menu-separator" />
      {externalURL ? (
        <ViewMenuButton
          icon="external"
          label={label("openSourceURL")}
          onClick={() => window.open(externalURL, "_blank", "noreferrer")}
        />
      ) : null}
      <ViewMenuButton
        checked={state.fileFilter.hideViewed}
        icon={state.fileFilter.hideViewed ? "eyeClosed" : "eye"}
        id="hide-viewed-toggle"
        label={label("hideViewedFiles")}
        onClick={onToggleHideViewed}
      />
      <ViewMenuButton
        checked={state.options.showBackgrounds}
        icon="background"
        label={state.options.showBackgrounds ? label("hideBackgrounds") : label("showBackgrounds")}
        onClick={() => onSetOption("showBackgrounds", !state.options.showBackgrounds)}
      />
      <ViewMenuButton
        checked={state.options.lineNumbers}
        icon="numbers"
        label={state.options.lineNumbers ? label("hideLineNumbers") : label("showLineNumbers")}
        onClick={() => onSetOption("lineNumbers", !state.options.lineNumbers)}
      />
      <div className="menu-item menu-segment">
        <Icon name="bars" />
        <span className="menu-label">{label("indicatorStyle")}</span>
        <span className="menu-segment-controls">
          {[
            { value: "bars", icon: "bars", label: label("bars") },
            { value: "classic", icon: "classic", label: label("classic") },
            { value: "none", icon: "none", label: label("none") },
          ].map((option) => (
            <button
              key={option.value}
              type="button"
              className="segment-button"
              title={option.label}
              aria-label={option.label}
              aria-pressed={state.options.diffIndicators === option.value}
              onClick={() => onSetOption("diffIndicators", option.value)}
            >
              <Icon name={option.icon as IconName} />
            </button>
          ))}
        </span>
      </div>
    </>
  );
}

function SourceControls({
  activeSessionSource,
  children,
  items,
  label,
  onNavigate,
  onSelectSessionSource,
  payload,
  rememberedBranch,
  transport,
}: {
  activeSessionSource: DiffSource | null;
  /** Controls after the source and base pills (the jump-to-file button). */
  children?: React.ReactNode;
  items: DiffItem[];
  label: DiffViewerLabelResolver;
  onNavigate: (url: string) => void;
  onSelectSessionSource: SelectSessionSource;
  payload: any;
  rememberedBranch: Extract<DiffSource, { kind: "branch" }> | null;
  transport: DiffTransport | null;
}) {
  const repoRoot =
    diffSourceRepoRoot(activeSessionSource) ??
    (typeof payload.repoRoot === "string" && payload.repoRoot !== "" ? payload.repoRoot : null);
  const sourceModel = sourceMenuModel({
    sourceOptions: payload.sourceOptions,
    repoRoot,
    activeSource: activeSessionSource,
    rememberedBranch,
    branchBaseRef: typeof payload.branchBaseRef === "string" ? payload.branchBaseRef : null,
    typedTransport: transport != null && activeSessionSource != null,
    isValidSource: validDiffSource,
  });
  const showSourceMenu = sourceModel.selected != null || sourceModel.sections.flat().some((entry) => entry.target);
  const totals = diffLineTotals(items);
  const selectSource = (target: SourceTarget) => {
    if (target.kind === "url") {
      onNavigate(target.url);
      return;
    }
    onSelectSessionSource(sourceSelectionWithActiveRepo(target.source, activeSessionSource));
  };
  return (
    <div className="toolbar-left flex min-w-0 items-center gap-1.5">
      {showSourceMenu ? (
        <SourceMenu
          additions={totals.additions}
          deletions={totals.deletions}
          label={label}
          model={sourceModel}
          onSelect={selectSource}
        />
      ) : null}
      {/* The repo select is ALWAYS rendered when the host lists several
          repositories. It shrinks and ellipsizes in place. */}
      {activeSessionSource?.kind !== "patch" ? (
        <NavigationSelect
          ariaLabel={label("repoPath")}
          fallbackValue={payload.repoRoot ?? ""}
          id="repo-select"
          options={payload.repoOptions}
          onNavigate={onNavigate}
          onSelectSessionSource={(source) =>
            onSelectSessionSource(repoSelectionWithActiveSource(source, activeSessionSource))
          }
          selectedOptionTitle
          selectedValue={diffSourceRepoRoot(activeSessionSource)}
        />
      ) : null}
      {sourceModel.selected?.id === "uncommitted" ? null : (
        <BaseControl
          activeSessionSource={activeSessionSource}
          label={label}
          onNavigate={onNavigate}
          onSelectSessionSource={onSelectSessionSource}
          payload={payload}
          transport={transport}
        />
      )}
      {children}
    </div>
  );
}

/**
 * Renders the searchable Base button+popover when the backend supplies
 * `payload.branchPicker` (FROZEN CONTRACT). Falls back to the legacy capped
 * `<select>` for older backends that only send `payload.baseOptions`.
 */
function BaseControl({
  activeSessionSource,
  label,
  onNavigate,
  onSelectSessionSource,
  payload,
  transport,
}: {
  activeSessionSource: DiffSource | null;
  label: DiffViewerLabelResolver;
  onNavigate: (url: string) => void;
  onSelectSessionSource: SelectSessionSource;
  payload: any;
  transport: DiffTransport | null;
}) {
  if (activeSessionSource?.kind === "branch" && transport) {
    const typedPicker: BranchPickerPayload = {
      repoRoot: activeSessionSource.repoRoot,
      capabilityToken: payload.capabilityToken,
      // The sidecar does not report the checked-out branch name; a host that
      // knows it can send `payload.headRef`.
      headRef: typeof payload.headRef === "string" && payload.headRef !== "" ? payload.headRef : "HEAD",
      currentRef: activeSessionSource.baseRef ?? "",
      currentReason: "",
      confidence: "high",
      aheadBehind: null,
      refsURL: "typed://branch-list",
      regenerateURLTemplate: "typed://branch-change/{ref}",
    };
    return (
      <BranchBasePicker
        key={branchPickerStateKey(typedPicker)}
        label={label}
        onNavigate={onNavigate}
        onSelectBranchBase={(baseRef) =>
          onSelectSessionSource({
            kind: "branch",
            repoRoot: activeSessionSource.repoRoot,
            baseRef,
          })
        }
        picker={typedPicker}
        transport={transport}
      />
    );
  }
  const picker = resolveBranchPicker(payload);
  if (picker) {
    return (
      <BranchBasePicker
        key={branchPickerStateKey(picker)}
        label={label}
        onNavigate={onNavigate}
        onBranchSessionOpened={(session) =>
          onSelectSessionSource(session.source, { session, capabilityToken: picker.capabilityToken ?? "" })
        }
        picker={picker}
        transport={transport}
      />
    );
  }
  return (
    <NavigationSelect
      ariaLabel={label("branchBase")}
      fallbackValue={payload.branchBaseRef ?? ""}
      id="base-select"
      options={payload.baseOptions}
      onNavigate={onNavigate}
    />
  );
}

// Reads the FROZEN CONTRACT `branchPicker` object. In dev, a `?cmuxBranchPickerMock=1`
// query flag injects a local sample so the popover can be exercised without a
// wired backend. Production behavior is unchanged when the flag is absent.
function resolveBranchPicker(payload: any): BranchPickerPayload | null {
  const value = payload?.branchPicker;
  // Opt into the new picker only when the full FROZEN CONTRACT shape is present:
  // refsURL and regenerateURLTemplate must be non-empty strings (selection does
  // `regenerateURLTemplate.replace(...)`, which throws if it is missing), and
  // currentRef/headRef must be strings (rendered in the button label). Anything
  // missing falls back to the legacy <select>.
  if (isValidBranchPickerPayload(value)) {
    return value;
  }
  if (import.meta.env?.DEV && devBranchPickerMockEnabled()) {
    return devBranchPickerMock();
  }
  return null;
}

function isValidBranchPickerPayload(value: any): value is BranchPickerPayload {
  return Boolean(
    value &&
    typeof value === "object" &&
    typeof value.refsURL === "string" &&
    value.refsURL !== "" &&
    typeof value.regenerateURLTemplate === "string" &&
    value.regenerateURLTemplate !== "" &&
    typeof value.currentRef === "string" &&
    typeof value.headRef === "string",
  );
}

function devBranchPickerMockEnabled(): boolean {
  try {
    return new URLSearchParams(window.location.search).get("cmuxBranchPickerMock") === "1";
  } catch {
    return false;
  }
}

function devBranchPickerMock(): BranchPickerPayload {
  return {
    repoRoot: "/tmp/mock-repo",
    headRef: "feat-x",
    currentRef: "main",
    currentReason: "fork point",
    confidence: "low",
    aheadBehind: { ahead: 12, behind: 3 },
    refsURL:
      "data:application/json," +
      encodeURIComponent(
        JSON.stringify({
          groups: [
            {
              id: "suggested",
              label: "Suggested",
              rows: [
                { ref: "main", label: "main", reason: "fork point", confidence: "low", current: true },
                { ref: "origin/main", label: "origin/main", reason: "PR base" },
              ],
            },
            {
              id: "worktrees",
              label: "Worktrees",
              rows: [{ ref: "feat-x", label: "feat-x", worktreeDir: "../worktrees/feat-x" }],
            },
            {
              id: "branches",
              label: "Branches",
              rows: [
                { ref: "develop", label: "develop", secondary: "2 days ago" },
                { ref: "release/1.0", label: "release/1.0", secondary: "1 week ago" },
              ],
            },
            // Large remotes group so the render cap (top N + "... more") is
            // exercisable in DEV without a wired backend.
            {
              id: "remotes",
              label: "Remotes",
              rows: Array.from({ length: 2304 }, (_value, index) => ({
                ref: `origin/feature-${index}`,
                label: `origin/feature-${index}`,
              })),
            },
          ],
        }),
      ),
    regenerateURLTemplate: "about:blank#base={ref}",
  };
}

function NavigationSelect({
  ariaLabel,
  fallbackValue,
  id,
  onNavigate,
  onSelectSessionSource,
  options,
  selectedOptionTitle = false,
  selectedValue,
}: {
  ariaLabel: string;
  fallbackValue: string;
  id: string;
  onNavigate: (url: string) => void;
  onSelectSessionSource?: (source: DiffSource) => void;
  options: any[] | undefined;
  selectedOptionTitle?: boolean;
  selectedValue?: string | null;
}) {
  if (!Array.isArray(options) || options.length < 2) {
    return null;
  }
  const selected =
    options.find((option) => option.value === selectedValue) ??
    options.find((option) => option.selected) ??
    options.find((option) => !option.disabled);
  const selectedTitle = selectedOptionTitle
    ? typeof selected?.message === "string" && selected.message.trim() !== ""
      ? selected.message
      : String(selected?.value ?? fallbackValue).trim() || ariaLabel
    : ariaLabel;
  return (
    <select
      id={id}
      aria-label={ariaLabel}
      value={selected?.value ?? fallbackValue}
      title={selectedTitle}
      onChange={(event) => {
        const next = options.find((option) => option.value === event.currentTarget.value);
        if (validDiffSource(next?.sessionSource) && onSelectSessionSource) {
          onSelectSessionSource(next.sessionSource);
          return;
        }
        if (!next?.url) {
          event.currentTarget.value = selected?.value ?? fallbackValue;
          return;
        }
        onNavigate(next.url);
      }}
    >
      {options.map((option) => (
        <option
          key={option.value}
          value={option.value}
          disabled={option.disabled || (!option.url && !validDiffSource(option.sessionSource))}
          title={option.message}
        >
          {option.label}
        </option>
      ))}
    </select>
  );
}
