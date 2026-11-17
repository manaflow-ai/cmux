import {
  useId,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type KeyboardEvent,
  type PointerEvent as ReactPointerEvent,
} from "react";
import { Button } from "../../../ui/Button";
import { focusRoute } from "../../../ui/focusRoute";
import { Input } from "../../../ui/Input";
import { Menu, MenuButton, MenuItem, MenuPopup } from "../../../ui/Menu";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "../../../ui/Tabs";
import { useRowState, useStore, type RowState } from "../context";
import { Icon } from "../icons";
import {
  BY_AGENT_KEY,
  BY_KIND_KEY,
  KINDS,
  LINES_KEY,
  MAX_AGENTS,
  MAX_LINES,
  PREVIEW_NAME,
  PREVIEW_SAMPLE,
  SLOTS,
  addToken,
  addable,
  agentId,
  layoutFromSwitches,
  lineFull,
  moveToken,
  problemPlace,
  problemToken,
  readLayout,
  readMap,
  refusalProblems,
  removeLine,
  removeToken,
  stepPlace,
  switchKey,
  toggleSlot,
  writeLayout,
  writeMap,
  type Kind,
  type Layout,
  type LayoutKey,
  type Place,
  type Problem,
  type Slot,
  type TextToken,
  type Token,
} from "../rowLayout";
import { rowsByKey } from "../schema";
import { valueOf } from "../store";
import { t, text } from "../strings";
import type { EditorProps } from "./types";

/** Pointer travel before a press on a chip becomes a drag (a plain click does nothing). */
const DRAG_THRESHOLD = 4;

type Tab = "all" | "kind" | "agent";
const TAB_OF: Record<LayoutKey, Tab> = { [LINES_KEY]: "all", [BY_KIND_KEY]: "kind", [BY_AGENT_KEY]: "agent" };

/** A refused write of one key: what the daemon said was wrong, and the value it refused. */
type Refusal = { problems: Problem[]; written: unknown };

/** A token's title: its element switch's (localized with the schema), the name the page's own. */
export function tokenTitle(token: Token): string {
  if (token === "name") return t("settingsPage.rowLayout.name");
  const row = rowsByKey.get(switchKey(token));
  return row ? text(row.title) : token;
}

const KIND_TITLES: Record<Kind, string> = {
  terminal: "settingsPage.rowLayout.kind.terminal",
  agent: "settingsPage.rowLayout.kind.agent",
  browser: "settingsPage.rowLayout.kind.browser",
  mixed: "settingsPage.rowLayout.kind.mixed",
};

function kindTitle(kind: Kind): string {
  return t(KIND_TITLES[kind]);
}

function usable(state: RowState): boolean {
  return state.connected && state.readable && state.managed === null;
}

/**
 * Settings > Sidebar > Workspace Rows > Row Layout (CMUX-383): the three layout settings in one
 * editor, a tab each. `row` names the tab it opens on (a search result or link for By Kind opens
 * there). Every write is a whole value inside the reducer's bounds; a refusal keeps the last good
 * layout (the store rolls back) and shows the daemon's problems beside the items they name. Use
 * Item Switches resets the shown setting, so the rows go back to the element switches.
 */
/** Focuses the grab handle of the chip at `at` inside the editor `root`. */
function focusChip(root: HTMLElement | null, at: Place) {
  focusRoute(
    root?.querySelector<HTMLElement>(
      `[data-layout-line="${at.line}"] [data-chip][data-index="${at.index}"] .row-layout-chip-grab`,
    ),
    "person",
    "row layout: the chip an arrow key, move or Delete lands on",
  );
}

export function RowLayoutEditor({ row, disabled, labelId }: EditorProps) {
  const store = useStore();
  const states = {
    [LINES_KEY]: useRowState(LINES_KEY),
    [BY_KIND_KEY]: useRowState(BY_KIND_KEY),
    [BY_AGENT_KEY]: useRowState(BY_AGENT_KEY),
  } as Record<LayoutKey, RowState>;
  const [tab, setTab] = useState<Tab>(TAB_OF[row.key as LayoutKey] ?? "all");
  const [refused, setRefused] = useState<Partial<Record<LayoutKey, Refusal>>>({});
  const off = (key: LayoutKey) => (key === row.key ? disabled : !usable(states[key]));
  const write = async (key: LayoutKey, value: unknown) => {
    const result = value === null ? await store.reset(key) : await store.set(key, value);
    setRefused((current) => {
      const next = { ...current };
      if (result.ok) delete next[key];
      else next[key] = { problems: refusalProblems(result.error.details), written: value };
      return next;
    });
  };
  // The layout a new override starts from: the All Rows layout when there is one, else today's row.
  const startLayout = (): Layout =>
    readLayout(states[LINES_KEY].value) ?? layoutFromSwitches((key) => valueOf(store.getSnapshot(), key));
  const panel = (key: LayoutKey) => ({
    disabled: off(key),
    refusal: refused[key],
    error: key === row.key ? undefined : states[key].error?.message,
  });
  return (
    <div className="row-layout" data-row-layout-editor="" aria-labelledby={labelId}>
      <Tabs variant="segmented" value={tab} onValueChange={(value) => setTab(value as Tab)}>
        <TabsList className="row-layout-tabs" aria-label={t("settingsPage.rowLayout.tabs")}>
          <TabsTrigger value="all" data-customized={states[LINES_KEY].customized ? "" : undefined}>
            {t("settingsPage.rowLayout.tab.all")}
          </TabsTrigger>
          <TabsTrigger value="kind" data-customized={states[BY_KIND_KEY].customized ? "" : undefined}>
            {t("settingsPage.rowLayout.tab.kind")}
          </TabsTrigger>
          <TabsTrigger value="agent" data-customized={states[BY_AGENT_KEY].customized ? "" : undefined}>
            {t("settingsPage.rowLayout.tab.agent")}
          </TabsTrigger>
        </TabsList>
        <TabsContent value="all" className="row-layout-panel">
          <AllRowsPanel
            value={states[LINES_KEY].value}
            {...panel(LINES_KEY)}
            onWrite={(value) => void write(LINES_KEY, value)}
            start={startLayout}
          />
        </TabsContent>
        <TabsContent value="kind" className="row-layout-panel">
          <KindsPanel
            value={states[BY_KIND_KEY].value}
            inherited={readLayout(states[LINES_KEY].value) !== null}
            {...panel(BY_KIND_KEY)}
            onWrite={(value) => void write(BY_KIND_KEY, value)}
            start={startLayout}
          />
        </TabsContent>
        <TabsContent value="agent" className="row-layout-panel">
          <AgentsPanel
            value={states[BY_AGENT_KEY].value}
            {...panel(BY_AGENT_KEY)}
            onWrite={(value) => void write(BY_AGENT_KEY, value)}
            start={startLayout}
          />
        </TabsContent>
      </Tabs>
    </div>
  );
}

type PanelProps = {
  value: unknown;
  disabled: boolean;
  refusal: Refusal | undefined;
  /** The store's refusal text for this key, when no problem list came with it. */
  error: string | undefined;
  /** Writes the setting's whole value; null resets it (the override goes, the default applies). */
  onWrite(value: unknown): void;
  start(): Layout;
};

/** All Rows (`lines`): one layout, or none (the element switches draw the row). */
function AllRowsPanel({ value, disabled, refusal, error, onWrite, start }: PanelProps) {
  const layout = useMemo(() => readLayout(value), [value]);
  return (
    <>
      {layout ? (
        <LayoutEditor
          layout={layout}
          disabled={disabled}
          problems={problemsFor(refusal, null)}
          label={t("settingsPage.rowLayout.tab.all")}
          onChange={(next) => onWrite(writeLayout(next))}
        />
      ) : (
        <p className="row-layout-empty">{t("settingsPage.rowLayout.empty.all")}</p>
      )}
      <PanelProblems refusal={refusal} entry={null} error={error} />
      <div className="row-layout-footer">
        {layout ? (
          <Button
            variant="ghost"
            size="sm"
            data-row-layout-action="reset"
            disabled={disabled}
            onClick={() => onWrite(null)}
          >
            <Icon name="reset" />
            {t("settingsPage.rowLayout.useSwitches")}
          </Button>
        ) : (
          <Button
            size="sm"
            data-row-layout-action="customize"
            disabled={disabled}
            onClick={() => onWrite(writeLayout(start()))}
          >
            {t("settingsPage.rowLayout.customize")}
          </Button>
        )}
      </div>
    </>
  );
}

/** By Kind (`linesByKind`): a layout per row kind, each optional. */
function KindsPanel({
  value,
  inherited,
  disabled,
  refusal,
  error,
  onWrite,
  start,
}: PanelProps & { inherited: boolean }) {
  const entries = useMemo(() => readMap(value), [value]);
  const of = new Map(entries);
  const set = (kind: Kind, layout: Layout | null) => {
    const next = writeMap(entries, kind, layout);
    // The last entry gone removes the setting, so nothing is left behind.
    onWrite(Object.keys(next).length === 0 ? null : next);
  };
  return (
    <>
      {KINDS.map((kind) => {
        const layout = of.get(kind);
        return (
          <section key={kind} className="row-layout-entry" data-row-layout-entry={kind}>
            <div className="row-layout-entry-head">
              <h4 className="row-layout-entry-title">{kindTitle(kind)}</h4>
              {!layout && (
                <span className="row-layout-entry-note">
                  {t(inherited ? "settingsPage.rowLayout.inheritsAll" : "settingsPage.rowLayout.inheritsSwitches")}
                </span>
              )}
              {layout ? (
                <Button
                  variant="ghost"
                  size="sm"
                  data-row-layout-action="remove-entry"
                  aria-label={`${t("settingsPage.remove")} ${kindTitle(kind)}`}
                  disabled={disabled}
                  onClick={() => set(kind, null)}
                >
                  {t("settingsPage.remove")}
                </Button>
              ) : (
                <Button
                  size="sm"
                  data-row-layout-action="customize-entry"
                  aria-label={`${t("settingsPage.rowLayout.customize")} ${kindTitle(kind)}`}
                  disabled={disabled}
                  onClick={() => set(kind, start())}
                >
                  {t("settingsPage.rowLayout.customize")}
                </Button>
              )}
            </div>
            {layout && (
              <LayoutEditor
                layout={layout}
                disabled={disabled}
                problems={problemsFor(refusal, kind)}
                label={kindTitle(kind)}
                onChange={(next) => set(kind, next)}
              />
            )}
            <PanelProblems refusal={refusal} entry={kind} />
          </section>
        );
      })}
      <PanelProblems refusal={refusal} entry={null} error={error} />
      {entries.length > 0 && (
        <div className="row-layout-footer">
          <Button
            variant="ghost"
            size="sm"
            data-row-layout-action="reset"
            disabled={disabled}
            onClick={() => onWrite(null)}
          >
            <Icon name="reset" />
            {t("settingsPage.rowLayout.removeAllKinds")}
          </Button>
        </div>
      )}
    </>
  );
}

/** By Agent (`linesByAgent`): a layout per agent id the person adds. */
function AgentsPanel({ value, disabled, refusal, error, onWrite, start }: PanelProps) {
  const entries = useMemo(() => readMap(value), [value]);
  const [draft, setDraft] = useState("");
  const fieldId = useId();
  const set = (id: string, layout: Layout | null) => {
    const next = writeMap(entries, id, layout);
    onWrite(Object.keys(next).length === 0 ? null : next);
  };
  const id = agentId(draft);
  const taken = id !== null && entries.some(([key]) => key === id);
  const full = entries.length >= MAX_AGENTS;
  const add = () => {
    if (id === null || taken || full) return;
    set(id, start());
    setDraft("");
  };
  return (
    <>
      {entries.length === 0 && <p className="row-layout-empty">{t("settingsPage.rowLayout.empty.agent")}</p>}
      {entries.map(([agent, layout]) => (
        <section key={agent} className="row-layout-entry" data-row-layout-entry={agent}>
          <div className="row-layout-entry-head">
            <h4 className="row-layout-entry-title row-layout-agent">{agent}</h4>
            <Button
              variant="ghost"
              size="sm"
              data-row-layout-action="remove-entry"
              aria-label={`${t("settingsPage.remove")} ${agent}`}
              disabled={disabled}
              onClick={() => set(agent, null)}
            >
              {t("settingsPage.remove")}
            </Button>
          </div>
          <LayoutEditor
            layout={layout}
            disabled={disabled}
            problems={problemsFor(refusal, agent)}
            label={agent}
            onChange={(next) => set(agent, next)}
          />
          <PanelProblems refusal={refusal} entry={agent} />
        </section>
      ))}
      <PanelProblems refusal={refusal} entry={null} error={error} />
      <div className="row-layout-add-agent">
        <label className="visually-hidden" htmlFor={fieldId}>
          {t("settingsPage.rowLayout.agentField")}
        </label>
        <Input
          id={fieldId}
          className="field row-layout-agent-field"
          size="sm"
          type="text"
          spellCheck={false}
          value={draft}
          maxLength={64}
          placeholder={t("settingsPage.rowLayout.agentPlaceholder")}
          disabled={disabled || full}
          aria-invalid={taken}
          onChange={(event) => setDraft(event.currentTarget.value)}
          onKeyDown={(event) => {
            if (event.key === "Enter") {
              event.preventDefault();
              add();
            }
          }}
        />
        <Button
          size="sm"
          data-row-layout-action="add-agent"
          disabled={disabled || id === null || taken || full}
          onClick={add}
        >
          {t("settingsPage.rowLayout.addAgent")}
        </Button>
        {entries.length > 0 && (
          <Button
            variant="ghost"
            size="sm"
            data-row-layout-action="reset"
            disabled={disabled}
            onClick={() => onWrite(null)}
          >
            <Icon name="reset" />
            {t("settingsPage.rowLayout.removeAllAgents")}
          </Button>
        )}
      </div>
      {taken && (
        <span className="field-error" role="alert">
          {t("settingsPage.rowLayout.agentTaken", id)}
        </span>
      )}
    </>
  );
}

/** The problems of a refusal that belong to one layout (`entry` null: the `lines` key's own). */
type LayoutProblem = { line: number | null; token: string | null; why: string };

function problemsFor(refusal: Refusal | undefined, entry: string | null): LayoutProblem[] {
  if (!refusal) return [];
  return refusal.problems.flatMap((problem) => {
    const place = problemPlace(problem.at);
    if (!place || place.entry !== entry) return [];
    return [{ line: place.line, token: problemToken(problem, refusal.written), why: problem.why }];
  });
}

/** A problem in the page's words. */
export function problemText(problem: { why: string; token: string | null; line: number | null }): string {
  const token = problem.token && isKnownToken(problem.token) ? tokenTitle(problem.token) : (problem.token ?? "");
  const line = String((problem.line ?? 0) + 1);
  switch (problem.why) {
    case "unknownToken":
      return t("settingsPage.rowLayout.problem.unknownToken", token);
    case "notAString":
      return t("settingsPage.rowLayout.problem.notAString", line);
    case "notALine":
      return t("settingsPage.rowLayout.problem.notALine", line);
    case "notALayout":
      return t("settingsPage.rowLayout.problem.notALayout");
    case "repeated":
      return t("settingsPage.rowLayout.problem.repeated", token);
    case "nameMoved":
      return t("settingsPage.rowLayout.problem.nameMoved");
    case "tooManyLines":
      return t("settingsPage.rowLayout.problem.tooManyLines", String(MAX_LINES));
    case "tooManyTokens":
      return t("settingsPage.rowLayout.problem.tooManyTokens", line);
    default:
      // A shape message from the daemon ("more than 3 items", "not an allowed name"): its own words.
      return t("settingsPage.rowLayout.problem.other", problem.why);
  }
}

function isKnownToken(token: string): token is Token {
  return token === "name" || rowsByKey.has(switchKey(token as Token));
}

/** Under a layout: what the last refused write of it had wrong, in words. */
function PanelProblems({
  refusal,
  entry,
  error,
}: {
  refusal: Refusal | undefined;
  entry: string | null;
  error?: string;
}) {
  const problems = problemsFor(refusal, entry);
  // A refusal with no problems of its own (an older daemon, a managed key): the store's reason.
  const fallback = entry === null && problems.length === 0 && (refusal || error) ? (error ?? null) : null;
  if (problems.length === 0 && !fallback) return null;
  return (
    <ul className="row-layout-problems" role="alert">
      {problems.map((problem, index) => (
        <li key={index} className="row-error" data-why={problem.why}>
          {problemText(problem)}
        </li>
      ))}
      {fallback && <li className="row-error">{fallback}</li>}
    </ul>
  );
}

type Drag = {
  pointerId: number;
  from: Place;
  x: number;
  y: number;
  started: boolean;
  /** Each line's box and its chips' boxes (the dragged one left out), measured as the drag starts. */
  lines: { top: number; bottom: number; left: number; chips: DOMRect[]; full: boolean }[];
  /** The Add Line row: dropping on it starts a new line (null at the line limit). */
  newLine: DOMRect | null;
};

type Drop = Place & { caret: { left: number; top: number; height: number } };

/**
 * One layout: the marks (slot toggles), then up to three lines of chips. The name leads line one
 * and stays there. A chip reorders by drag (pointer events, as Settings > Menus: a native drag runs
 * in AppKit's loop and its drop is not the person's gesture) or by Option and the arrow keys;
 * Delete or its x removes it.
 */
function LayoutEditor({
  layout,
  disabled,
  problems,
  label,
  onChange,
}: {
  layout: Layout;
  disabled: boolean;
  problems: LayoutProblem[];
  label: string;
  onChange(layout: Layout): void;
}) {
  const root = useRef<HTMLDivElement>(null);
  const drag = useRef<Drag | null>(null);
  const [dragging, setDragging] = useState<{ from: Place; dx: number; dy: number } | null>(null);
  const [drop, setDropState] = useState<Drop | null>(null);
  const dropRef = useRef<Drop | null>(null);
  const setDrop = (next: Drop | null) => {
    dropRef.current = next;
    setDropState(next);
  };
  /** A chip to focus once the layout an edit wrote draws (`after`: the layout before the edit). */
  const focus = useRef<{ at: Place; after: Layout } | null>(null);
  useLayoutEffect(() => {
    const pending = focus.current;
    if (!pending || pending.after === layout) return;
    focus.current = null;
    focusChip(root.current, pending.at);
  });
  const hintId = useId();
  const options = addable(layout);
  const flagged = new Set(problems.flatMap((problem) => (problem.token ? [problem.token] : [])));
  const lineFlagged = new Set(
    problems.flatMap((problem) => (problem.token === null && problem.line !== null ? [problem.line] : [])),
  );
  const change = (next: Layout, focusAt?: Place) => {
    if (next === layout) return;
    focus.current = focusAt ? { at: focusAt, after: layout } : null;
    onChange(next);
  };

  const measure = (from: Place): Drag["lines"] => {
    const box = root.current;
    if (!box) return [];
    return [...box.querySelectorAll<HTMLElement>("[data-layout-line]")].map((line, index) => {
      const rect = line.getBoundingClientRect();
      const chips = [...line.querySelectorAll<HTMLElement>("[data-chip]")]
        .filter((chip) => !(index === from.line && Number(chip.dataset.index) === from.index))
        .map((chip) => chip.getBoundingClientRect());
      const area = line.querySelector<HTMLElement>(".row-layout-chips")!.getBoundingClientRect();
      return {
        top: rect.top,
        bottom: rect.bottom,
        left: area.left,
        chips,
        full: index !== from.line && lineFull(layout, index),
      };
    });
  };

  const target = (state: Drag, x: number, y: number): Drop | null => {
    const origin = root.current?.getBoundingClientRect();
    if (!origin) return null;
    if (state.newLine && y >= state.newLine.top) {
      const line = layout.lines.length;
      if (layout.lines[state.from.line]!.length === 1 && state.from.line === line - 1) return null;
      return {
        line,
        index: 0,
        caret: {
          left: state.newLine.left - origin.left,
          top: state.newLine.top - origin.top,
          height: state.newLine.height,
        },
      };
    }
    // The line whose band holds the pointer, else the nearest.
    let best = 0;
    let distance = Number.POSITIVE_INFINITY;
    state.lines.forEach((line, index) => {
      const d = y < line.top ? line.top - y : y > line.bottom ? y - line.bottom : 0;
      if (d < distance) {
        distance = d;
        best = index;
      }
    });
    const line = state.lines[best];
    if (!line || line.full) return null;
    const index = line.chips.filter((chip) => chip.left + chip.width / 2 < x).length;
    const before = line.chips[index];
    const after = line.chips[index - 1];
    const left = before ? before.left - 3 : after ? after.right + 1 : line.left;
    const height = (before ?? after)?.height ?? line.bottom - line.top;
    const top = (before ?? after)?.top ?? line.top;
    return { line: best, index, caret: { left: left - origin.left, top: top - origin.top, height } };
  };

  const onPointerDown = (event: ReactPointerEvent<HTMLElement>, from: Place) => {
    if (disabled || event.button !== 0) return;
    drag.current = {
      pointerId: event.pointerId,
      from,
      x: event.clientX,
      y: event.clientY,
      started: false,
      lines: [],
      newLine: null,
    };
    event.currentTarget.setPointerCapture?.(event.pointerId);
  };
  const onPointerMove = (event: ReactPointerEvent<HTMLElement>) => {
    const state = drag.current;
    if (!state || state.pointerId !== event.pointerId) return;
    const dx = event.clientX - state.x;
    const dy = event.clientY - state.y;
    if (!state.started) {
      if (Math.hypot(dx, dy) < DRAG_THRESHOLD) return;
      state.started = true;
      state.lines = measure(state.from);
      const add = root.current?.querySelector<HTMLElement>("[data-new-line]");
      state.newLine = add ? add.getBoundingClientRect() : null;
    }
    setDragging({ from: state.from, dx, dy });
    setDrop(target(state, event.clientX, event.clientY));
  };
  const endDrag = (commit: boolean) => {
    const state = drag.current;
    const current = dropRef.current;
    drag.current = null;
    setDragging(null);
    setDrop(null);
    if (commit && state?.started && current) change(moveToken(layout, state.from, current));
  };

  const onChipKey = (event: KeyboardEvent<HTMLElement>, at: Place) => {
    if (disabled || event.metaKey || event.ctrlKey) return;
    const arrows: Record<string, "left" | "right" | "up" | "down"> = {
      ArrowLeft: "left",
      ArrowRight: "right",
      ArrowUp: "up",
      ArrowDown: "down",
    };
    const direction = arrows[event.key];
    if (event.key === "Delete" || event.key === "Backspace") {
      event.preventDefault();
      const line = layout.lines[at.line]!;
      const next = removeToken(layout, at);
      // Focus stays in the line: the chip that took its place, else the one before it.
      const stays = line.length > 1 || at.line === 0;
      change(next, stays ? { line: at.line, index: Math.max(0, Math.min(at.index, line.length - 2)) } : undefined);
      return;
    }
    if (!direction) return;
    event.preventDefault();
    if (event.altKey) {
      const to = stepPlace(layout, at, direction);
      if (!to) return;
      const next = moveToken(layout, at, to);
      // A move that emptied the line above the target shifts the target up one.
      const emptied = at.line > 0 && layout.lines[at.line]!.length === 1 && to.line > at.line;
      change(next, emptied ? { line: to.line - 1, index: to.index } : to);
      return;
    }
    const flat = layout.lines.flatMap((line, l) => line.map((_, i) => ({ line: l, index: i })));
    const here = flat.findIndex((place) => place.line === at.line && place.index === at.index);
    const step = direction === "left" || direction === "up" ? -1 : 1;
    const next = flat[here + step];
    if (next) focusChip(root.current, next);
  };

  const slotTitle = (slot: Slot) => tokenTitle(slot);
  return (
    <div ref={root} className="row-layout-editor" data-layout-label={label} data-reordering={dragging ? "" : undefined}>
      <span id={hintId} className="visually-hidden">
        {t("settingsPage.rowLayout.chipHint")}
      </span>
      <RowPreview layout={layout} />
      <div className="row-layout-marks">
        <span className="row-layout-line-label">{t("settingsPage.rowLayout.marks")}</span>
        <div className="row-layout-chips">
          {SLOTS.map((slot) => (
            <button
              key={slot}
              type="button"
              className="ui-button row-layout-slot"
              data-slot={slot}
              aria-pressed={layout.slots.has(slot)}
              disabled={disabled}
              onClick={() => change(toggleSlot(layout, slot))}
            >
              <span className="row-layout-slot-check" aria-hidden="true">
                {layout.slots.has(slot) && <Icon name="check" />}
              </span>
              {slotTitle(slot)}
            </button>
          ))}
        </div>
      </div>
      {layout.lines.map((line, l) => (
        <div
          key={l}
          className="row-layout-line"
          data-layout-line={l}
          data-problem={lineFlagged.has(l) ? "" : undefined}
          data-drop={drop?.line === l ? "" : undefined}
        >
          <span className="row-layout-line-label">{t("settingsPage.rowLayout.line", String(l + 1))}</span>
          <ul className="row-layout-chips" aria-label={t("settingsPage.rowLayout.line", String(l + 1))}>
            {l === 0 && (
              <li className="row-layout-chip" data-pinned="">
                <Icon name="lock" className="row-layout-pin" />
                <span className="row-layout-chip-name">{tokenTitle("name")}</span>
                <span className="visually-hidden">{t("settingsPage.rowLayout.namePinned")}</span>
              </li>
            )}
            {line.map((token, i) => {
              const at = { line: l, index: i };
              const lifted = dragging?.from.line === l && dragging.from.index === i;
              return (
                <li
                  key={token}
                  className="row-layout-chip"
                  data-chip={token}
                  data-index={i}
                  data-problem={flagged.has(token) ? "" : undefined}
                  data-dragging={lifted ? "" : undefined}
                  style={lifted ? { transform: `translate(${dragging.dx}px, ${dragging.dy}px)` } : undefined}
                >
                  {/* The chip's grab handle and keyboard stop: drag it, or Option and an arrow key. */}
                  <button
                    type="button"
                    className="row-layout-chip-grab"
                    aria-label={t("settingsPage.rowLayout.chip", tokenTitle(token), String(l + 1), String(i + 1))}
                    aria-describedby={hintId}
                    disabled={disabled}
                    onPointerDown={(event) => onPointerDown(event, at)}
                    onPointerMove={onPointerMove}
                    onPointerUp={() => endDrag(true)}
                    onPointerCancel={() => endDrag(false)}
                    onKeyDown={(event) => onChipKey(event, at)}
                  >
                    {tokenTitle(token)}
                  </button>
                  <Button
                    icon
                    size="sm"
                    variant="ghost"
                    className="token-remove row-layout-chip-remove"
                    tabIndex={-1}
                    aria-label={`${t("settingsPage.remove")} ${tokenTitle(token)}`}
                    disabled={disabled}
                    onClick={() => change(removeToken(layout, at))}
                  >
                    <Icon name="xmark" />
                  </Button>
                </li>
              );
            })}
            <li className="row-layout-add-item">
              <AddItemMenu
                label={t("settingsPage.rowLayout.addItemTo", String(l + 1))}
                options={options}
                disabled={disabled || lineFull(layout, l) || options.length === 0}
                onPick={(token) => change(addToken(layout, l, token))}
              />
            </li>
          </ul>
          {l > 0 && (
            <Button
              icon
              size="sm"
              variant="ghost"
              className="icon-button row-layout-remove-line"
              aria-label={t("settingsPage.rowLayout.removeLine", String(l + 1))}
              disabled={disabled}
              onClick={() => change(removeLine(layout, l))}
            >
              <Icon name="xmark" />
            </Button>
          )}
        </div>
      ))}
      {layout.lines.length < MAX_LINES && (
        <div
          className="row-layout-line row-layout-new-line"
          data-new-line=""
          data-drop={drop && drop.line === layout.lines.length ? "" : undefined}
        >
          <span className="row-layout-line-label" aria-hidden="true" />
          <AddItemMenu
            label={t("settingsPage.rowLayout.addLine")}
            text={t("settingsPage.rowLayout.addLine")}
            options={options}
            disabled={disabled || options.length === 0}
            onPick={(token) => change(addToken(layout, layout.lines.length, token))}
          />
        </div>
      )}
      {drop && dragging && (
        <span
          className="row-layout-caret"
          aria-hidden="true"
          style={{ left: drop.caret.left, top: drop.caret.top, height: drop.caret.height }}
        />
      )}
    </div>
  );
}

/**
 * The row as this layout draws it, with sample values: the icon, the name and line one's items,
 * then each further line, its items joined by a dot (Herdr's rows), the progress bar under them.
 */
function RowPreview({ layout }: { layout: Layout }) {
  const has = (slot: Slot) => layout.slots.has(slot);
  const label = t("settingsPage.rowLayout.preview");
  return (
    <div className="row-layout-preview-row">
      <span className="row-layout-line-label" aria-hidden="true">
        {label}
      </span>
      <div className="row-layout-preview" data-row-layout-preview="" role="group" aria-label={label}>
        {layout.lines.map((line, l) => (
          <div key={l} className="row-layout-preview-line" data-preview-line={l}>
            {l === 0 && has("icon") && (
              <span className="row-layout-preview-icon" data-preview-slot="icon" aria-hidden="true" />
            )}
            {l === 0 && <span className="row-layout-preview-name">{PREVIEW_NAME}</span>}
            {line.map((token) => (
              <span key={token} className="row-layout-preview-item" data-token={token}>
                {PREVIEW_SAMPLE[token]}
              </span>
            ))}
            {l === 0 && has("working") && (
              <span className="row-layout-preview-working" data-preview-slot="working" aria-hidden="true" />
            )}
          </div>
        ))}
        {has("progress") && (
          <span className="row-layout-preview-progress" data-preview-slot="progress" aria-hidden="true" />
        )}
      </div>
    </div>
  );
}

/** The + after a line's chips (or Add Line): a menu of the items the layout does not use yet. */
function AddItemMenu({
  label,
  text: shown,
  options,
  disabled,
  onPick,
}: {
  label: string;
  text?: string;
  options: TextToken[];
  disabled: boolean;
  onPick(token: TextToken): void;
}) {
  return (
    <Menu>
      <MenuButton
        className={shown ? "button row-layout-add-line" : "button row-layout-add"}
        label={label}
        data-menu="row-layout-add"
        disabled={disabled}
        aria-haspopup="menu"
      >
        <Icon name="plus" />
        {shown && <span>{shown}</span>}
      </MenuButton>
      <MenuPopup align="start">
        {options.map((token) => (
          <MenuItem key={token} data-value={token} onSelect={() => onPick(token)}>
            {tokenTitle(token)}
          </MenuItem>
        ))}
      </MenuPopup>
    </Menu>
  );
}
