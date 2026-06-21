import { useEffect, useId, useRef, useState } from "react";
import { createPortal } from "react-dom";
import { Icon } from "./icons";
import type { DiffViewerLabelResolver, DiffViewerLabelKey } from "./labels";

/**
 * Searchable, uncapped branch base picker. Renders a heavy toolbar button that
 * opens a command-palette-style popover anchored beneath it. Replaces the capped
 * base `<select>` when the backend supplies `payload.branchPicker` (FROZEN
 * CONTRACT). Selecting a ref navigates to the regenerate URL, which replaces the
 * page; the button only needs to show a transient spinner until that navigation.
 */

export type BranchPickerPayload = {
  repoRoot: string;
  headRef: string;
  currentRef: string;
  currentReason: string;
  confidence: "high" | "low";
  aheadBehind: { ahead: number; behind: number } | null;
  refsURL: string;
  regenerateURLTemplate: string;
};

type BranchPickerRow = {
  ref: string;
  label: string;
  secondary?: string;
  reason?: string;
  confidence?: "high" | "low";
  current?: boolean;
  worktreeDir?: string;
};

type BranchPickerGroup = {
  id: string;
  label: string;
  rows: BranchPickerRow[];
};

type RefsResponse = { groups: BranchPickerGroup[] };

// Strip a leading `scheme://host[:port]` so the URL becomes root-relative and
// resolves against the CURRENT document origin. The persisted diff HTML embeds
// `refsURL`/`regenerateURLTemplate` as ABSOLUTE URLs with the HTTP origin
// (`http://127.0.0.1:<port>/...`) that was live when the page was generated.
// After session-restore/app-restart the page is served through the custom
// scheme (`cmux-diff-viewer://<token>/...`) and the HTTP port changes, so the
// embedded absolute URL points at a dead origin. Rebasing to a root-relative
// path makes it resolve correctly under BOTH origins: the HTTP server routes
// `/__cmux_diff_viewer_*` specially regardless of the token path segment, and
// the custom-scheme handler intercepts the same path under the token host.
//
// Uses a string strip rather than `new URL(...)`: the regenerate template
// carries a literal `{ref}` placeholder that URL parsing would percent-encode.
// Only a real `scheme://host` origin is stripped, so an already-relative path
// or a non-origin URL (e.g. the dev mock's `data:` refsURL) passes through
// unchanged.
export function toCurrentOriginRelative(url: string): string {
  return url.replace(/^[a-zA-Z][\w+.-]*:\/\/[^/]*/, "");
}

// A flattened, filtered row paired with its rendered group header. `match`
// carries the fuzzy-match span for bolding while filtering. `raw` marks the
// synthetic "Use <query> (raw)" row.
type FlatRow = {
  row: BranchPickerRow;
  groupId: string;
  groupLabel: string;
  firstInGroup: boolean;
  match: [number, number] | null;
  raw: boolean;
  // Hidden-row count when this is the last rendered row of a group whose tail
  // was capped (empty filter only). Renders a muted "... N more" footer beneath
  // the row; the footer is not selectable and not part of keyboard navigation.
  moreCount: number;
};

// Per-group render cap when the filter is empty: huge ref lists (thousands of
// remotes) would jank the popover if every row became DOM. The data is fetched
// once; this only limits rendered rows. Suggested/Worktrees are usually small,
// so they keep a higher cap. Typing switches to a flat, global filter cap.
const EMPTY_FILTER_GROUP_CAP: Record<string, number> = {
  suggested: 50,
  worktrees: 50,
};
const EMPTY_FILTER_DEFAULT_CAP = 8;
const FILTERED_TOTAL_CAP = 50;

const GROUP_LABEL_KEY: Record<string, DiffViewerLabelKey> = {
  suggested: "branchPickerGroupSuggested",
  worktrees: "branchPickerGroupWorktrees",
  branches: "branchPickerGroupBranches",
  remotes: "branchPickerGroupRemotes",
  recent: "branchPickerGroupRecent",
};

// Inline `position: fixed` style for the popover, recomputed from the Base
// button's viewport rect. Only the fields the popover needs to override. When
// flipped above the button, `top` is `auto` and `bottom` anchors it to just
// above the button so a short popover stays glued to the button, not the
// viewport top.
type PopoverStyle = Pick<React.CSSProperties, "top" | "bottom" | "left" | "maxHeight">;

// Popover sizing constants. Width matches `.base-picker-popover` (320px) so the
// right-edge clamp is correct; the gap matches the CSS `top: calc(100% + 6px)`.
const POPOVER_WIDTH = 320;
const POPOVER_GAP = 6;
// Keep at least this much breathing room from each viewport edge.
const VIEWPORT_MARGIN = 8;
// Don't bother flipping above unless the popover can be at least this tall there.
const POPOVER_MIN_HEIGHT = 160;

// Anchor the fixed popover under (or above) the Base button, clamped to the
// viewport. Horizontal: align to the button's left edge, but shift left so the
// 320px popover never overruns the right edge. Vertical: prefer below the
// button; flip above when there is more room there, and cap max-height to the
// space available on the chosen side so the list scrolls instead of overflowing
// the viewport. The popover is portaled to `document.body`, so this fixed
// element resolves against the viewport, escaping the toolbar cell's
// container-query containing block and its `overflow-x: clip`.
function computePopoverStyle(rect: DOMRect): PopoverStyle {
  const viewportWidth = window.innerWidth;
  const viewportHeight = window.innerHeight;

  const maxLeft = viewportWidth - POPOVER_WIDTH - VIEWPORT_MARGIN;
  const left = Math.max(VIEWPORT_MARGIN, Math.min(rect.left, maxLeft));

  const spaceBelow = viewportHeight - rect.bottom - POPOVER_GAP - VIEWPORT_MARGIN;
  const spaceAbove = rect.top - POPOVER_GAP - VIEWPORT_MARGIN;
  // Flip above only when below is too cramped AND above is genuinely roomier.
  const flipAbove = spaceBelow < POPOVER_MIN_HEIGHT && spaceAbove > spaceBelow;

  if (flipAbove) {
    return {
      top: "auto",
      // Anchor the popover's bottom POPOVER_GAP above the button top; it grows
      // upward and a short popover stays glued just above the button.
      bottom: viewportHeight - rect.top + POPOVER_GAP,
      left,
      maxHeight: Math.max(0, spaceAbove),
    };
  }
  return {
    top: rect.bottom + POPOVER_GAP,
    bottom: "auto",
    left,
    maxHeight: Math.max(0, spaceBelow),
  };
}

export function BranchBasePicker({
  label,
  onNavigate,
  picker,
}: {
  label: DiffViewerLabelResolver;
  onNavigate: (url: string) => void;
  picker: BranchPickerPayload;
}) {
  const [open, setOpen] = useState(false);
  const [query, setQuery] = useState("");
  const [groups, setGroups] = useState<BranchPickerGroup[] | null>(null);
  const [loadState, setLoadState] = useState<"idle" | "loading" | "error">("idle");
  const [highlight, setHighlight] = useState(0);
  const [generatingRef, setGeneratingRef] = useState<string | null>(null);
  // Inline position for the viewport-anchored (position: fixed) popover. Null
  // until the first measurement after open, so the popover is not painted at a
  // stale 0,0 for a frame. Recomputed on open, resize, and ancestor scroll.
  const [popoverStyle, setPopoverStyle] = useState<PopoverStyle | null>(null);

  const containerRef = useRef<HTMLDivElement | null>(null);
  // The popover is portaled to `document.body`, so it is NOT a descendant of
  // `containerRef`. Track its root separately so the outside-click handler keeps
  // the popover open when a click lands inside it (search input, a row).
  const popoverRef = useRef<HTMLDivElement | null>(null);
  const buttonRef = useRef<HTMLButtonElement | null>(null);
  const listboxId = useId();

  // Callback ref: the filter input is rendered only while the popover is open,
  // so it mounts each time the popover opens. Focusing it here gives the same
  // open-time focus as autoFocus without the a11y-flagged autoFocus attribute
  // (noAutofocus) and without a raw useEffect.
  const focusFilterInput = (node: HTMLInputElement | null) => {
    node?.focus();
  };

  const flat = buildFlatRows(groups, query, label);
  const clampedHighlight = flat.length === 0 ? 0 : Math.min(highlight, flat.length - 1);

  const openPopover = () => {
    setOpen(true);
    setQuery("");
    setHighlight(0);
    if (groups == null && loadState !== "loading") {
      setLoadState("loading");
      fetchRefs(toCurrentOriginRelative(picker.refsURL))
        .then((response) => {
          setGroups(response.groups);
          setLoadState("idle");
        })
        .catch((error) => {
          console.warn("cmux diff branch picker refs load failed", error);
          setLoadState("error");
        });
    }
  };

  const closePopover = () => {
    setOpen(false);
    buttonRef.current?.focus();
  };

  const selectRef = (ref: string) => {
    const trimmed = ref.trim();
    if (trimmed === "") {
      return;
    }
    setGeneratingRef(trimmed);
    setOpen(false);
    onNavigate(
      toCurrentOriginRelative(picker.regenerateURLTemplate).replace("{ref}", encodeURIComponent(trimmed)),
    );
  };

  // Outside-click dismissal while open. Isolated to one effect with a narrow
  // contract; keyboard nav inside the popover is handled on the input. Because
  // the popover is portaled to `document.body` it is not inside `containerRef`,
  // so a click inside it would otherwise read as "outside" and close it; keep it
  // open when the target is inside EITHER the picker cell or the portaled popover.
  useEffect(() => {
    if (!open) {
      return;
    }
    const onPointerDown = (event: MouseEvent) => {
      if (!(event.target instanceof Node)) {
        return;
      }
      const target = event.target;
      if (containerRef.current?.contains(target) || popoverRef.current?.contains(target)) {
        return;
      }
      setOpen(false);
    };
    document.addEventListener("mousedown", onPointerDown);
    return () => document.removeEventListener("mousedown", onPointerDown);
  }, [open]);

  // Viewport-anchor the popover while open. The popover is `position: fixed` and
  // portaled to `document.body`, so it escapes `.toolbar-left`'s container-query
  // containing block and `overflow-x: clip` and renders fully over the diff
  // content. One effect gated on
  // `open`: it positions under the Base button, clamped to the viewport (shift
  // left if it would overrun the right edge, flip above if there is more room
  // there, cap max-height to the chosen side), and recomputes on resize and
  // ancestor scroll so it stays glued to the moving button. All listeners are
  // removed on close/unmount.
  useEffect(() => {
    if (!open) {
      setPopoverStyle(null);
      return;
    }
    const reposition = () => {
      const button = buttonRef.current;
      if (!button) {
        return;
      }
      setPopoverStyle(computePopoverStyle(button.getBoundingClientRect()));
    };
    reposition();
    window.addEventListener("resize", reposition);
    // Capture phase so scrolling ANY ancestor (not just window) repositions it.
    window.addEventListener("scroll", reposition, true);
    return () => {
      window.removeEventListener("resize", reposition);
      window.removeEventListener("scroll", reposition, true);
    };
  }, [open]);

  const onInputKeyDown = (event: React.KeyboardEvent<HTMLInputElement>) => {
    if (event.key === "Escape") {
      event.preventDefault();
      closePopover();
      return;
    }
    if (event.key === "ArrowDown") {
      event.preventDefault();
      if (flat.length > 0) {
        setHighlight((value) => (value + 1) % flat.length);
      }
      return;
    }
    if (event.key === "ArrowUp") {
      event.preventDefault();
      if (flat.length > 0) {
        setHighlight((value) => (value - 1 + flat.length) % flat.length);
      }
      return;
    }
    if (event.key === "Enter") {
      event.preventDefault();
      const target = flat[clampedHighlight];
      if (target) {
        selectRef(target.row.ref);
      }
      return;
    }
  };

  const buttonText = generatingRef != null
    ? label("branchPickerGenerating").replace("{ref}", generatingRef)
    : null;

  // The visual `title` exposes the full, untruncated label on hover so a
  // narrowed button (ref ellipsized, reason/ahead-behind shed by container
  // queries) still surfaces the complete value. The aria-label stays the action
  // label ("Change diff base") for assistive tech. While generating, the button
  // is disabled and shows its own transient text, so fall back to the action.
  const buttonTitle = generatingRef != null
    ? label("branchPickerOpen")
    : baseButtonTitle(label, picker);

  return (
    <div id="base-picker" ref={containerRef}>
      <button
        ref={buttonRef}
        id="base-picker-button"
        type="button"
        className="base-picker-button"
        aria-haspopup="listbox"
        aria-expanded={open}
        aria-controls={open ? listboxId : undefined}
        aria-label={label("branchPickerOpen")}
        title={buttonTitle}
        data-generating={generatingRef != null ? "true" : "false"}
        disabled={generatingRef != null}
        onClick={() => (open ? setOpen(false) : openPopover())}
      >
        {generatingRef != null ? (
          <>
            <span className="base-picker-spinner" aria-hidden="true" />
            <span className="base-picker-text">{buttonText}</span>
          </>
        ) : (
          <BranchBaseButtonLabel picker={picker} />
        )}
      </button>
      {open && popoverStyle ? createPortal(
        <div
          ref={popoverRef}
          className="base-picker-popover"
          // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
          role="dialog"
          aria-label={label("branchPickerOpen")}
          style={popoverStyle}
        >
          <div className="base-picker-search">
            <Icon name="search" />
            <input
              ref={focusFilterInput}
              type="text"
              className="base-picker-input"
              placeholder={label("branchPickerFilterPlaceholder")}
              aria-label={label("branchPickerFilterPlaceholder")}
              aria-controls={listboxId}
              aria-activedescendant={flat[clampedHighlight] ? rowDomId(listboxId, clampedHighlight) : undefined}
              value={query}
              onChange={(event) => {
                setQuery(event.currentTarget.value);
                setHighlight(0);
              }}
              onKeyDown={onInputKeyDown}
            />
          </div>
          {/* Searchable command-palette listbox; a native select/datalist cannot
              render grouped rows with secondaries, pills, and matched bolding. */}
          {/* oxlint-disable-next-line jsx-a11y/prefer-tag-over-role */}
          <div id={listboxId} className="base-picker-list" role="listbox" aria-label={label("branchPickerOpen")}>
            {loadState === "loading" ? (
              <div className="base-picker-status">{label("branchPickerLoading")}</div>
            ) : loadState === "error" ? (
              <div className="base-picker-status base-picker-status-error">{label("branchPickerLoadFailed")}</div>
            ) : flat.length === 0 ? (
              <div className="base-picker-status">{label("branchPickerNoMatches")}</div>
            ) : (
              flat.map((entry, index) => (
                <BranchPickerRowView
                  // Stable identity key: groupId + ref. A ref is unique within a
                  // group, and the groupId prefix disambiguates the same ref
                  // appearing in two groups (e.g. Suggested vs Worktrees), so the
                  // key survives filter rebuilds (no array-index key).
                  key={`${entry.groupId}:${entry.row.ref}`}
                  domId={rowDomId(listboxId, index)}
                  entry={entry}
                  label={label}
                  selected={index === clampedHighlight}
                  onHover={() => setHighlight(index)}
                  onSelect={() => selectRef(entry.row.ref)}
                />
              ))
            )}
          </div>
        </div>,
        document.body,
      ) : null}
    </div>
  );
}

// Full, untruncated button label as a plain string for the visual `title`
// tooltip. Mirrors what BranchBaseButtonLabel renders: `Comparing <head>
// against <base> (<reason>) +<ahead> -<behind>`, with the low-confidence `~`
// prefix and omitting empty parts, so a truncated button still exposes the
// complete comparison on hover.
function baseButtonTitle(label: DiffViewerLabelResolver, picker: BranchPickerPayload): string {
  const low = picker.confidence === "low";
  const parts = [
    label("branchPickerComparing")
      .replace("{head}", picker.headRef)
      .replace("{base}", picker.currentRef),
  ];
  if (picker.currentReason) {
    parts.push(`(${low ? "~" : ""}${picker.currentReason})`);
  }
  if (picker.aheadBehind) {
    parts.push(`+${picker.aheadBehind.ahead} -${picker.aheadBehind.behind}`);
  }
  return parts.join(" ");
}

function BranchBaseButtonLabel({
  picker,
}: {
  picker: BranchPickerPayload;
}) {
  const low = picker.confidence === "low";
  const reason = `${low ? "~" : ""}${picker.currentReason}`;
  const aheadBehind = picker.aheadBehind;
  return (
    <span className="base-picker-label">
      {/* Head side: read-only context. It ellipsizes BEFORE the base ref (it has
          a smaller min-width floor and lower priority), but stays visible while
          space allows. The arrow points head -> base. */}
      <span className="base-picker-head">{picker.headRef}</span>
      <Icon name="arrow" />
      <span className="base-picker-ref">{picker.currentRef}</span>
      {/* Secondaries live in their own flex group that absorbs all the shrink
          (high flex-shrink + overflow:hidden), so as the toolbar narrows the
          ahead/behind clips first, then the reason, and the ref is only forced
          to ellipsize once this group has fully collapsed. Keeps the base ref
          the last token to truncate regardless of font or panel width. */}
      {picker.currentReason || aheadBehind ? (
        <span className="base-picker-meta">
          {picker.currentReason ? (
            <span className={low ? "base-picker-reason base-picker-reason-low" : "base-picker-reason"}>
              ({reason})
            </span>
          ) : null}
          {aheadBehind ? (
            <span className="base-picker-aheadbehind">
              +{aheadBehind.ahead} -{aheadBehind.behind}
            </span>
          ) : null}
        </span>
      ) : null}
      <Icon name="expand" />
    </span>
  );
}

function BranchPickerRowView({
  domId,
  entry,
  label,
  onHover,
  onSelect,
  selected,
}: {
  domId: string;
  entry: FlatRow;
  label: DiffViewerLabelResolver;
  onHover: () => void;
  onSelect: () => void;
  selected: boolean;
}) {
  const { row } = entry;
  // Prefer the backend's localized `secondary` (e.g. the localized reason label
  // for Suggested rows) over the raw English `reason` contract tag so non-English
  // diff viewers don't show "fork point" / "created from" verbatim.
  const secondary = row.secondary ?? row.worktreeDir ?? row.reason ?? "";
  return (
    <>
      {entry.firstInGroup ? (
        <div className="base-picker-group-header" role="presentation">
          {entry.groupLabel}
        </div>
      ) : null}
      {/* Virtual-focus listbox option: focus stays on the search input and is
          tracked via aria-activedescendant, so the option is not tab-focusable.
          A native <option> cannot host the row layout / matched-substring bolding. */}
      <div
        id={domId}
        // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
        role="option"
        tabIndex={-1}
        aria-selected={selected}
        className={selected ? "base-picker-row base-picker-row-selected" : "base-picker-row"}
        onMouseMove={onHover}
        onMouseDown={(event) => {
          // Keep input focus; select on click without blurring the field.
          event.preventDefault();
          onSelect();
        }}
      >
        <span className="base-picker-row-primary">
          {entry.raw
            ? label("branchPickerUseRaw").replace("{ref}", row.ref)
            : renderMatched(row.label, entry.match)}
        </span>
        {row.current ? <span className="base-picker-pill">{label("branchPickerCurrent")}</span> : null}
        {secondary ? <span className="base-picker-row-secondary">{secondary}</span> : null}
      </div>
      {entry.moreCount > 0 ? (
        <div className="base-picker-more" role="presentation">
          {label("branchPickerMore").replace("{count}", String(entry.moreCount))}
        </div>
      ) : null}
    </>
  );
}

function rowDomId(listboxId: string, index: number): string {
  return `${listboxId}-row-${index}`;
}

function renderMatched(text: string, match: [number, number] | null) {
  if (!match) {
    return text;
  }
  const [start, end] = match;
  return (
    <>
      {text.slice(0, start)}
      <strong>{text.slice(start, end)}</strong>
      {text.slice(end)}
    </>
  );
}

// Flatten groups into a render list. While filtering, fuzzy-match each row's
// primary label across all groups, drop non-matches, and compute the matched
// span for bolding. A synthetic raw row is prepended when the query matches no
// row. Empty groups are omitted (no header) per LOCKED DECISIONS.
export function buildFlatRows(
  groups: BranchPickerGroup[] | null,
  query: string,
  label: DiffViewerLabelResolver,
): FlatRow[] {
  const trimmed = query.trim();
  const result: FlatRow[] = [];
  let anyMatch = false;

  if (groups && trimmed === "") {
    // Empty filter: render each group up to its cap, then a "... N more" footer
    // on the last visible row of any group whose tail was dropped.
    for (const group of groups) {
      const groupLabel = resolveGroupLabel(group, label);
      const cap = EMPTY_FILTER_GROUP_CAP[group.id] ?? EMPTY_FILTER_DEFAULT_CAP;
      const visible = group.rows.slice(0, cap);
      const hidden = group.rows.length - visible.length;
      visible.forEach((row, index) => {
        result.push({
          row,
          groupId: group.id,
          groupLabel,
          firstInGroup: index === 0,
          match: null,
          raw: false,
          moreCount: index === visible.length - 1 ? hidden : 0,
        });
      });
    }
  } else if (groups) {
    // Filtering: match across ALL rows of every group, then cap the total
    // rendered set so a query that matches thousands of rows stays cheap.
    for (const group of groups) {
      if (result.length >= FILTERED_TOTAL_CAP) {
        break;
      }
      const groupLabel = resolveGroupLabel(group, label);
      let firstInGroup = true;
      for (const row of group.rows) {
        if (result.length >= FILTERED_TOTAL_CAP) {
          break;
        }
        const match = fuzzyMatchSpan(row.label, trimmed);
        if (match == null) {
          continue;
        }
        anyMatch = true;
        result.push({
          row,
          groupId: group.id,
          groupLabel,
          firstInGroup,
          match,
          raw: false,
          moreCount: 0,
        });
        firstInGroup = false;
      }
    }
  }

  // Raw ref escape hatch: when a non-empty query matches nothing, offer it as a
  // top synthetic row that selects the typed value verbatim.
  if (trimmed !== "" && !anyMatch) {
    result.unshift({
      row: { ref: trimmed, label: trimmed },
      groupId: "__raw",
      groupLabel: "",
      firstInGroup: false,
      match: null,
      raw: true,
      moreCount: 0,
    });
  }
  return result;
}

function resolveGroupLabel(group: BranchPickerGroup, label: DiffViewerLabelResolver): string {
  const key = GROUP_LABEL_KEY[group.id];
  if (key) {
    return label(key);
  }
  return group.label || group.id;
}

// Subsequence fuzzy match (case-insensitive). Returns the [start, end) span of
// the first contiguous run that begins the match, used only for bolding; any
// subsequence hit qualifies the row. Returns null on no match.
function fuzzyMatchSpan(text: string, query: string): [number, number] | null {
  const haystack = text.toLowerCase();
  const needle = query.toLowerCase();
  const contiguous = haystack.indexOf(needle);
  if (contiguous >= 0) {
    return [contiguous, contiguous + needle.length];
  }
  // Subsequence fallback: every needle char appears in order.
  let queryIndex = 0;
  let firstHit = -1;
  for (let textIndex = 0; textIndex < haystack.length && queryIndex < needle.length; textIndex += 1) {
    if (haystack[textIndex] === needle[queryIndex]) {
      if (firstHit < 0) {
        firstHit = textIndex;
      }
      queryIndex += 1;
    }
  }
  if (queryIndex < needle.length) {
    return null;
  }
  // Bold only the first matched char for subsequence hits (cheap, readable).
  return firstHit >= 0 ? [firstHit, firstHit + 1] : null;
}

async function fetchRefs(refsURL: string): Promise<RefsResponse> {
  const response = await fetch(refsURL, { cache: "no-store" });
  if (!response.ok) {
    throw new Error(`refs request failed (${response.status})`);
  }
  const data = (await response.json()) as RefsResponse;
  if (!data || !Array.isArray(data.groups)) {
    throw new Error("refs response missing groups");
  }
  return data;
}
