// The model button's menu as columns (Lucas 2026-11-03, the omni picker's "Col · Profile"): every
// choice in view at once, left to right in the order it narrows. The harness rail (Starred, then
// each model family), the family's models, then the shown model's settings (its effort levels and
// Fast mode). The account is an avatar above the rail, as a browser's profile button: it shows the
// family's account with the family's mark at its corner, and a click opens a card that switches it.
// A click applies at once and the menu stays open; Return closes it. Left and Right move between
// the columns, Up and Down within one.
import React, { Fragment, useCallback, useContext, useLayoutEffect, useMemo, useRef, useState } from "react";
import { AgentMark } from "../shared/AgentMark";
import { Popover, type UiVirtualAnchor } from "../../ui/Popover";
import { usePopoverTrigger } from "../../ui/popoverTrigger";
import { DrivenList, DrivenRow, InlineCard } from "../../ui/DrivenList";
import { SlidingIndicator } from "../../ui/motion/SlidingIndicator";
import { isMousePress } from "../../ui/pressRelease";
import { useOpenSide } from "../../ui/openSide";
import { AddAccountDialog } from "./AddAccountDialog";
import { SearchIcon, reasoningChoices, type Choice } from "./ComposerPickers";
import { isDefaultChoice } from "./defaultChoice";
import { useT } from "./i18n";
import { OnNewTab } from "./newTabComposer";
import { isModelRouterKind } from "./routerKinds";
import { authLoginText, authText, canSessionLogin } from "./sessionAuth";
import { useChatAccounts, type ChatAccount } from "./chatAccounts";
import {
  QuickModelMenu,
  StarIcon,
  familyTabs,
  initialOf,
  leadRoute,
  runsOffers,
  searchGroups,
  symbolOf,
  twinRows,
  useAccountList,
  type QuickFamily,
  type QuickMenu,
  type QuickModel,
} from "./QuickModelMenu";
import "./quickModelColumns.css";

type Column = 0 | 1 | 2;

/// A row of the settings column: an effort level, a provider of a model several serve, or Fast mode.
type TuneRow =
  | { kind: "level"; choice: Choice }
  | { kind: "offer"; offer: QuickModel & { provider: string } }
  | { kind: "fast" };

const HUES = [250, 160, 30, 300, 200, 90];

/// The Starred tab's id when the picker sends none (nothing starred yet).
const STARRED_TAB = "\u0000starred";

/// What the avatar draws: an account's initial on a fill of its own, a key for an API key, or a
/// person for the harness's own login.
type Face = { id: string; name: string; glyph?: "key" | "person" };

function faceOf(account: ChatAccount | undefined, fallback: string): Face {
  if (!account) return { id: fallback, name: fallback, glyph: "person" };
  return { id: account.id, name: account.name, ...(account.kind === "direct-api-key" ? { glyph: "key" } : {}) };
}

function Avatar({ face, size, badge }: { face?: Face; size: number; badge?: string }) {
  let sum = 0;
  for (let i = 0; i < (face?.id.length ?? 0); i++) sum += face!.id.charCodeAt(i);
  const hue = HUES[sum % HUES.length]!;
  const b = Math.round(size * 0.5);
  return (
    <span className="acpmux-cols-avatar-wrap" style={{ width: size, height: size }}>
      <span
        className="acpmux-cols-avatar"
        data-empty={face ? undefined : ""}
        aria-hidden="true"
        style={{
          width: size,
          height: size,
          fontSize: Math.round(size * 0.45),
          ...(face ? { background: `oklch(0.62 0.09 ${hue})` } : {}),
        }}
      >
        {!face || face.glyph === "person" ? (
          <svg width={size * 0.56} height={size * 0.56} viewBox="0 0 12 12">
            <circle cx="6" cy="4.2" r="2.1" fill="none" stroke="currentColor" strokeWidth="1.1" />
            <path
              d="M2.2 10.6c.6-2 2-3 3.8-3s3.2 1 3.8 3"
              fill="none"
              stroke="currentColor"
              strokeWidth="1.1"
              strokeLinecap="round"
            />
          </svg>
        ) : face.glyph === "key" ? (
          <svg width={size * 0.5} height={size * 0.5} viewBox="0 0 12 12">
            <circle cx="4" cy="6" r="2.4" fill="none" stroke="currentColor" strokeWidth="1.4" />
            <path d="M6.3 6H11M9.4 6v1.8" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" />
          </svg>
        ) : (
          initialOf(face.name)
        )}
      </span>
      {badge && (
        <span className="acpmux-cols-avatar-badge" style={{ width: b, height: b }}>
          <AgentMark agent={badge} size={Math.round(b * 0.72)} />
        </span>
      )}
    </span>
  );
}

const CheckIcon = () => (
  <svg width="12" height="12" viewBox="0 0 12 12" aria-hidden="true">
    <path
      d="M2.5 6.2 5 8.6l4.6-5.2"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.6"
      strokeLinecap="round"
      strokeLinejoin="round"
    />
  </svg>
);

const PlusIcon = () => (
  <svg width="12" height="12" viewBox="0 0 12 12" aria-hidden="true">
    <path d="M6 2v8M2 6h8" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" />
  </svg>
);

/// Marks a scrolling column with the edges that have more rows past them (`data-fade-top`,
/// `data-fade-bottom`), so CSS fades that edge: a sign the column scrolls.
function markFades(list: HTMLElement) {
  const more = list.scrollHeight - list.clientHeight > 1;
  list.toggleAttribute("data-fade-top", more && list.scrollTop > 1);
  list.toggleAttribute("data-fade-bottom", more && list.scrollTop + list.clientHeight < list.scrollHeight - 1);
}

/// Keeps a column's highlighted row in view as the keyboard moves it.
function useRowInView(list: React.RefObject<HTMLDivElement | null>, key: unknown) {
  // oxlint-disable-next-line react-hooks/exhaustive-deps -- `key` names the highlighted row; the effect reads the DOM
  useLayoutEffect(() => {
    list.current?.querySelector<HTMLElement>("[data-hl]")?.scrollIntoView?.({ block: "nearest" });
  }, [list, key]);
}

type QuickSurfaceProps = React.ComponentProps<typeof QuickModelMenu>;

/// The model button's menu: columns where it has a rail, else the list menu (a menu with no rail,
/// or the Chief's, which picks its own model).
export function QuickModelColumns(props: QuickSurfaceProps) {
  const { families } = props.menu;
  if (!families || props.menu.ownModel) return <QuickModelMenu {...props} />;
  return <Columns {...props} menu={{ ...props.menu, families }} />;
}

/// Whether `chip` sits in a row packed to its end (justify-content flex-end), where its start
/// moves with its width. Rows drawn as display: contents, and wrappers that hug the chip, pass to
/// their parent.
function rowPackedToEnd(chip: HTMLElement): boolean {
  const view = chip.ownerDocument.defaultView;
  let child: HTMLElement = chip;
  for (let row = chip.parentElement; row && view; row = row.parentElement) {
    const style = view.getComputedStyle(row);
    if (style.display === "contents") continue;
    // A wrapper as wide as what it holds (the picker's own box) is no row: its parent may be.
    if (row.getBoundingClientRect().width - child.getBoundingClientRect().width <= 1) {
      child = row;
      continue;
    }
    if (!style.display.includes("flex")) return false;
    return ["flex-end", "end", "right"].includes(style.justifyContent);
  }
  return false;
}

function Columns({
  open,
  onOpenChange,
  trigger,
  chip,
  menu,
  children,
}: QuickSurfaceProps & { menu: QuickMenu & { families: NonNullable<QuickMenu["families"]> } }) {
  const t = useT();
  const newTab = useContext(OnNewTab);
  const { open: sideOpen, setOpen: setSideOpen, side } = useOpenSide(trigger, newTab ? "bottom" : "top", 280);
  if (sideOpen !== open) setSideOpen(open);
  // Where the keyboard goes as the menu closes: a close after a pick leaves it to the picker,
  // which focuses the prompt; any other close gives it to the chip, once the popup has gone (after
  // a pointerup's own focus), unless the press put it somewhere else (the prompt, another control).
  // Each open counts one: a menu reopened before the chip takes the keyboard (⌘⌃M right after
  // Escape) keeps it in its search field.
  const opens = useRef(0);
  useLayoutEffect(() => {
    if (open) opens.current += 1;
  }, [open]);
  const returnToChip = () => {
    const chip = button.current ?? trigger.current;
    const closedAt = opens.current;
    const doc = chip?.ownerDocument;
    const view = doc?.defaultView;
    if (!chip || !doc || !view) return;
    // A page with no frames (a test DOM) waits a task instead.
    const frame = (run: () => void) =>
      typeof view.requestAnimationFrame === "function" ? view.requestAnimationFrame(run) : view.setTimeout(run, 0);
    frame(() =>
      frame(() => {
        if (opens.current !== closedAt) return;
        const active = doc.activeElement;
        if (!active || active === doc.body || active.closest(".acpmux-cols")) chip.focus({ preventScroll: true });
      }),
    );
  };
  /// `back`: a key closed the menu (Escape, Return, a digit), so the keyboard goes back to the chip.
  /// A press elsewhere (another chip, the prompt) keeps the focus it gave.
  const finish = (next: boolean, back = false) => {
    if (!next && !pendingRef.current && back) returnToChip();
    onOpenChange(next);
  };
  const press = usePopoverTrigger(open, finish);
  // The menu's own button, read each time the popup is placed: a composer can remount its controls
  // row as the menu opens, and an element read once at render then has no box (the menu went to
  // the page's top left on New Tab).
  const button = useRef<HTMLButtonElement | null>(null);
  // The chip's edge that stays put as its name changes: in a row packed to its end (the chat's quiet
  // row) a longer or shorter name moves the chip's start, so the menu lines up with its end and never
  // jumps as a model, a level or Fast changes the chip.
  const [align, setAlign] = useState<"start" | "end">("start");
  useLayoutEffect(() => {
    const chip = button.current ?? trigger.current;
    if (open && chip) setAlign(rowPackedToEnd(chip) ? "end" : "start");
  }, [open, trigger]);
  // The menu stays where it opened while it is open: a pick lands at once and renames the chip, and a
  // longer or shorter name never moves the menu under the pointer. A resized window places it again.
  const pinned = useRef<{ rect: DOMRect; width: number; height: number } | undefined>(undefined);
  useLayoutEffect(() => {
    if (!open) pinned.current = undefined;
  }, [open]);
  const anchor = useMemo<UiVirtualAnchor>(
    () => ({
      getBoundingClientRect: () => {
        const chip = button.current ?? trigger.current;
        const view = chip?.ownerDocument.defaultView;
        const size = { width: view?.innerWidth ?? 0, height: view?.innerHeight ?? 0 };
        const pin = pinned.current;
        if (pin && pin.width === size.width && pin.height === size.height) return pin.rect;
        const rect = chip?.getBoundingClientRect() ?? new DOMRect();
        pinned.current = rect.width > 0 ? { rect, ...size } : undefined;
        return rect;
      },
      get contextElement() {
        return button.current ?? trigger.current ?? undefined;
      },
    }),
    [trigger],
  );
  const { families, current, effort, fast, auth, search } = menu;
  const account = menu.ownModel ? undefined : menu.account;
  const accounts = useAccountList(open, account);
  const [addingAccount, setAddingAccount] = useState(false);

  const [tab, setTab] = useState(families.current);
  const [query, setQuery] = useState("");
  const [col, setCol] = useState<Column>(1);
  // The rail's focus ring shows only when the arrows moved there, never after a click on a tab.
  const [railKeys, setRailKeys] = useState(false);
  // The model whose settings show: the arrows' or the pointer's row, by its place in the list.
  const [modelHl, setModelHl] = useState(-1);
  const [tuneHl, setTuneHl] = useState(0);
  // Return runs the settings row the arrows reached; after a click on one it only closes, so it never
  // turns a Fast just switched on off again.
  const [tuneKeys, setTuneKeys] = useState(false);
  const [profileOpen, setProfileOpen] = useState(false);
  // The running model's level or Fast shows at once, until the session reports its own.
  const [held, setHeld] = useState<{ key: string; effort?: string; fast?: boolean }>();
  // A pick of another model (with its level, Fast or provider) lands at once and keeps the menu open;
  // its check shows until the session reports the model.
  type Pending = { model: QuickModel; viaSearch: boolean };
  const [pending, setPendingState] = useState<Pending>();
  const pendingRef = useRef<Pending | undefined>(undefined);
  const setPending = (next: Pending | undefined) => {
    pendingRef.current = next;
    setPendingState(next);
  };
  // The last level picked here, on any model: the next model clicked carries it.
  const [chosenLevel, setChosenLevel] = useState<string>();
  const [seen, setSeen] = useState({ effort: effort?.current, fast: fast?.checked });
  if (seen.effort !== effort?.current || seen.fast !== fast?.checked) {
    setSeen({ effort: effort?.current, fast: fast?.checked });
    setHeld(undefined);
  }
  const field = useRef<HTMLInputElement | null>(null);
  // The field takes the keyboard as it mounts, not a frame later: a menu reopened at once (⌘⌃M right
  // after a pick) has its keys from the first one. Stable, so a re-render never runs it again: it
  // would take the keyboard back from another chip's menu that just opened.
  const fieldRef = useCallback((node: HTMLInputElement | null) => {
    field.current = node;
    if (node && !node.ownerDocument.activeElement?.closest(".acpmux-cols")) node.focus({ preventScroll: true });
  }, []);
  // A reopen while the closed popup is still mounted (its fade) keeps the same field, so the ref
  // above never runs again: take the keyboard as the menu opens, not a frame later.
  useLayoutEffect(() => {
    const node = field.current;
    if (open && node && !node.ownerDocument.activeElement?.closest(".acpmux-cols")) node.focus({ preventScroll: true });
  }, [open]);
  const updateAction = useRef<HTMLButtonElement | null>(null);
  // The menu never shrinks while open: a tab, a search or a model with fewer rows keeps its size, so
  // the edge away from the chip stays put. The floor is the largest it has been since it opened; the
  // observer goes with the frame, which unmounts as the menu closes.
  const sizeHold = useRef<ResizeObserver | null>(null);
  // The columns' fades follow their scroll, their size (the menu grows, the window shrinks) and their
  // rows (a tab or a search changes them). The observers go with the body as the menu closes.
  const fadeWatch = useRef<(() => void) | null>(null);
  const bodyRef = useCallback((body: HTMLDivElement | null) => {
    fadeWatch.current?.();
    fadeWatch.current = null;
    if (!body || typeof ResizeObserver === "undefined" || typeof MutationObserver === "undefined") return;
    const lists = [...body.querySelectorAll<HTMLElement>(":scope > .acpmux-cols-list")];
    const all = () => lists.forEach(markFades);
    const sized = new ResizeObserver(all);
    const rows = new MutationObserver(all);
    for (const list of lists) {
      sized.observe(list);
      rows.observe(list, { childList: true });
    }
    all();
    fadeWatch.current = () => {
      sized.disconnect();
      rows.disconnect();
    };
  }, []);
  const frameRef = useCallback((frame: HTMLDivElement | null) => {
    sizeHold.current?.disconnect();
    sizeHold.current = null;
    const popup = frame?.parentElement;
    if (!frame || !popup || typeof ResizeObserver === "undefined") return;
    let width = 0;
    let height = 0;
    const observer = new ResizeObserver(() => {
      const box = frame.getBoundingClientRect();
      if (box.width > width) {
        width = box.width;
        popup.style.minWidth = `min(${width}px, var(--available-width, calc(100vw - 24px)))`;
      }
      if (box.height > height) {
        height = box.height;
        // Never past the frame's own cap: min-height beats max-height.
        frame.style.minHeight = `min(${height}px, 259px, var(--available-height, 259px))`;
      }
    });
    observer.observe(frame);
    sizeHold.current = observer;
  }, []);
  const modelsList = useRef<HTMLDivElement | null>(null);
  const railList = useRef<HTMLDivElement | null>(null);

  // The Starred tab is always the rail's first, also before anything is starred.
  const starredText = t("picker.starred");
  const list = useMemo<QuickFamily[]>(
    () =>
      families.list.some((family) => family.starred)
        ? families.list
        : [{ id: STARRED_TAB, name: starredText, starred: true, models: [], more: [] }, ...families.list],
    [families.list, starredText],
  );
  const shown = list.find((family) => family.id === tab);
  const tabs = useMemo(() => familyTabs(list), [list]);
  const shownTab = tabs.find((entry) => entry.routes.some((route) => route.id === tab));
  const tabName = shownTab?.name ?? shown?.name ?? "";
  const found = useMemo(() => (query && search ? search.find(query) : undefined), [query, search]);
  const groups = useMemo(
    () => (found ? searchGroups(found, list, families.current) : undefined),
    [found, list, families],
  );
  // Rows a search lists twice under one name (two routes of one model) also name their model id.
  const twins = useMemo(() => twinRows(groups ?? []), [groups]);
  // The list: a search's matches under their family's name, else the tab's models, then its Legacy ones.
  const rows: QuickModel[] = groups
    ? groups.flatMap((group) => group.rows)
    : shown && !shown.fork
      ? [...shown.models, ...shown.more]
      : [];
  const legacyFrom = groups || !shown ? rows.length : shown.models.length;
  const isRunning = (model: QuickModel) =>
    model.family === families.current && (model.id === current || runsOffers(model, current));
  const runningIndex = rows.findIndex(isRunning);

  // Reset as the menu opens, in render: the composer re-renders while it is open (a streaming
  // reply), and an effect on the families would throw away the tab and the typed filter.
  const [wasOpen, setWasOpen] = useState(open);
  if (open !== wasOpen) {
    setWasOpen(open);
    if (open) {
      const first = families.current ?? list.find((family) => !family.starred)?.id;
      setTab(first);
      setQuery("");
      setCol(1);
      setRailKeys(false);
      setTuneKeys(false);
      setTuneHl(0);
      setProfileOpen(false);
      setModelHl(-1);
      setHeld(undefined);
      setPending(undefined);
      setChosenLevel(undefined);
    }
  }

  // Until the arrows or the pointer move it, the running model's row is the one shown, else the
  // first one: the settings column always shows the model its rows apply to, never an empty column.
  const firstIndex = rows.findIndex((model) => !model.disabled);
  const hl = modelHl >= 0 && modelHl < rows.length ? modelHl : runningIndex >= 0 ? runningIndex : firstIndex;
  // The chat's own tab with no row for the running model (its catalog has not loaded, or does not
  // list it) still shows the session's levels and Fast, as the list menu's Effort row did.
  const sessionRow: QuickModel | undefined =
    hl < 0 && current && families.current && (!shown || shown.id === families.current)
      ? { id: current, name: current, family: families.current }
      : undefined;
  const focus = hl >= 0 ? rows[hl] : sessionRow;
  const focusRuns = !!focus && isRunning(focus);
  // The running model's levels are the session's (Ultracode included); another model's are its catalog's.
  const sessionLevels = effort?.levels.filter((choice) => !isDefaultChoice(choice)) ?? [];
  const levelsOf = (model: QuickModel): Choice[] => {
    if (model.efforts?.length === 0) return [];
    if (isRunning(model)) return sessionLevels;
    if (!model.efforts) return [];
    return reasoningChoices(
      model.efforts.map((value) => ({ value })),
      { efforts: model.efforts, ...(model.defaultEffort ? { defaultEffort: model.defaultEffort } : {}) },
      t,
    );
  };
  /// The level another model carries (Opus 5.5 on Extra High to Sonnet 5.5 on Extra High): the
  /// last one picked here, else the chat's, when that model has it, else the model's recommended
  /// one. Ultracode carries as Extra High, the level it rides. None when the model has no levels.
  const carriedLevel = (model: QuickModel) => {
    const choices = levelsOf(model);
    if (!choices.length) return undefined;
    const has = (id: string | undefined) => !!id && choices.some((choice) => choice.id === id);
    const now = chosenLevel ?? held?.effort ?? effort?.current;
    if (has(now)) return now;
    if (now === "ultracode" && has("xhigh")) return "xhigh";
    return model.defaultEffort ?? choices.find((choice) => choice.recommended)?.id;
  };
  // Highest first, as a ladder.
  const ladder = focus ? [...levelsOf(focus)].reverse() : [];
  const keyOf = (model: QuickModel) => `${model.family}\u0000${model.id}`;
  const focusKey = focus ? keyOf(focus) : "";
  const mine = focusRuns && held?.key === focusKey ? held : undefined;
  // The held pick when it is the shown model (or one of its providers).
  const picked =
    pending &&
    focus &&
    (keyOf(pending.model) === focusKey || focus.offers?.some((o) => keyOf(o) === keyOf(pending.model)))
      ? pending.model
      : undefined;
  const level =
    picked?.effort ??
    mine?.effort ??
    (focus ? (focusRuns ? effort?.current : (focus.effort ?? carriedLevel(focus))) : undefined);
  // A level shows a check when it is really chosen: the session's, or one picked here.
  const levelChosen = focusRuns || !!picked?.effort;
  const canLandEffort = focusRuns ? !!effort : menu.inlineEffort === true;
  const offers = focus?.offers && focus.offers.length > 1 ? focus.offers : [];
  const runningOffer = picked
    ? focus?.offers?.find((offer) => keyOf(offer) === keyOf(picked))
    : focus?.offers?.find((offer) => offer.id === current && focus.family === families.current);
  const fastShown = focus ? (focusRuns ? !!fast : !!focus.canFast) : false;
  const fastOn = picked
    ? !!picked.fast
    : (mine?.fast ?? (focus ? (focusRuns ? !!fast?.checked : !!focus.fast) : false));
  // A model the harness cannot start takes no level, provider or Fast.
  const focusOff = !!focus?.disabled;
  /// The row that shows the check: the held pick, else the running model.
  const isChosen = (model: QuickModel) =>
    pending
      ? keyOf(model) === keyOf(pending.model) || !!model.offers?.some((o) => keyOf(o) === keyOf(pending.model))
      : isRunning(model);
  const tuneRows: TuneRow[] = [
    ...ladder.map((choice) => ({ kind: "level" as const, choice })),
    ...offers.map((offer) => ({ kind: "offer" as const, offer })),
    ...(fastShown ? [{ kind: "fast" as const }] : []),
  ];

  useRowInView(modelsList, `${tab}:${query}:${hl}`);
  useRowInView(railList, tab);

  const close = () => finish(false, true);
  /// Lands `model` at once, with a level and Fast set exactly (never copied from a searched row); the
  /// menu stays open.
  const hold = (model: QuickModel, choice: { effort?: string; fast?: boolean }) => {
    if (model.disabled) return;
    const { effort: _effort, fast: _fast, ...base } = model;
    const pick: Pending = {
      model: { ...base, ...(choice.effort ? { effort: choice.effort } : {}), ...(choice.fast ? { fast: true } : {}) },
      viaSearch: !!query,
    };
    setPending(pick);
    if (pick.viaSearch && menu.search) menu.search.pick(pick.model);
    else menu.families.onPick(pick.model);
  };
  /// The level another model lands with: the carried one. None when there is no way to land one
  /// with the model.
  const inheritedLevel = (model: QuickModel) => (menu.inlineEffort === true ? carriedLevel(model) : undefined);
  const pickModel = (index: number) => {
    const model = rows[index];
    if (!model || model.disabled) return;
    setModelHl(index);
    setTuneHl(0);
    // The running model again: nothing to land, unless a search named a level or Fast for it.
    if (isRunning(model) && !model.effort && !model.fast) setPending(undefined);
    else hold(model, { effort: model.effort ?? inheritedLevel(model), fast: model.fast });
  };
  const pickLevel = (value: string) => {
    if (!focus || focusOff || !canLandEffort) return;
    setChosenLevel(value);
    if (focusRuns && effort && !picked) {
      setHeld({ ...mine, key: focusKey, effort: value });
      effort.onPick(value);
    } else hold(picked ?? focus, { effort: value, fast: fastOn });
  };
  const toggleFast = () => {
    if (!focus || focusOff) return;
    const on = !fastOn;
    // A pick lands Fast only on (a combo never turns it off): off on a model that runs goes through
    // the session, also right after it was picked here.
    if (focusRuns && fast && (!picked || !on)) {
      setHeld({ ...mine, key: focusKey, fast: on });
      fast.onChange(on);
      if (picked && pending) {
        const { fast: _fast, ...rest } = picked;
        setPending({ ...pending, model: rest });
      }
    } else hold(picked ?? focus, { ...(picked?.effort ? { effort: picked.effort } : {}), fast: on });
  };
  /// A provider of the shown model: it keeps the level and Fast already picked here.
  const pickOffer = (offer: QuickModel) => {
    if (focusOff) return;
    hold(offer, { ...(picked?.effort ? { effort: picked.effort } : {}), fast: fastOn });
  };
  const runTune = (index: number) => {
    const row = tuneRows[index];
    if (!row) return;
    if (row.kind === "level") pickLevel(row.choice.id);
    else if (row.kind === "offer") pickOffer(row.offer);
    else toggleFast();
  };
  /// A rail tab: a family with one route that only starts its harness starts it, as the old rail did.
  const showTab = (index: number) => {
    const entry = tabs[index];
    if (!entry) return;
    const family = leadRoute(entry, families.current);
    if (entry.routes.length === 1 && family.launch && !family.note) {
      if (families.forkReady === false) return;
      close();
      families.onLaunch?.(family.id);
      return;
    }
    setTab(family.id);
    setQuery("");
    setProfileOpen(false);
    setTuneHl(0);
    setModelHl(-1);
  };
  /// The arrows only show a tab: a launch-only one starts its harness on a click, never on a pass.
  const moveTab = (index: number) => {
    const entry = tabs[index];
    if (!entry) return;
    setTab(leadRoute(entry, families.current).id);
    setQuery("");
    setProfileOpen(false);
    setTuneHl(0);
    setModelHl(-1);
  };
  const showRoute = (route: QuickFamily) => {
    if (route.launch && !route.note) {
      if (families.forkReady === false) return;
      close();
      families.onLaunch?.(route.id);
      return;
    }
    setTab(route.id);
    setQuery("");
    setProfileOpen(false);
    setModelHl(-1);
  };

  const keyDown = (event: React.KeyboardEvent<HTMLDivElement>) => {
    // ⌘1 to ⌘9 pick a row as 1 to 9 do, also while a search shows (where a bare digit is text).
    const commandDigit = event.metaKey && !event.ctrlKey && !event.altKey && /^[1-9]$/.test(event.key);
    if ((event.metaKey && !commandDigit) || event.ctrlKey || event.altKey || event.nativeEvent.isComposing) return;
    // A focused button (the avatar, a card row, a star) keeps its own Return and Space.
    if (event.target !== field.current && event.target !== event.currentTarget) return;
    const step = event.key === "ArrowDown" ? 1 : event.key === "ArrowUp" ? -1 : 0;
    const clamp = (n: number, length: number) => Math.max(0, Math.min(length - 1, n));
    if (step) {
      event.preventDefault();
      if (col === 0) {
        setRailKeys(true);
        const at = tabs.findIndex((entry) => entry === shownTab);
        moveTab(clamp(at + step, tabs.length));
      } else if (col === 1) {
        // Down past the last model reaches the update footer, as the list menu's arrows did.
        if (step > 0 && updateAction.current && (rows.length === 0 || hl === rows.length - 1)) {
          updateAction.current.focus();
          updateAction.current.scrollIntoView?.({ block: "nearest" });
          return;
        }
        if (rows.length) setModelHl(clamp((hl < 0 ? (step > 0 ? -1 : rows.length) : hl) + step, rows.length));
        setTuneHl(0);
      } else {
        setTuneKeys(true);
        setTuneHl((index) => clamp(index + step, tuneRows.length));
      }
      return;
    }
    // Left and Right edit a typed search; on an empty field they move between the columns.
    if ((event.key === "ArrowLeft" || event.key === "ArrowRight") && !query) {
      event.preventDefault();
      const next = (event.key === "ArrowLeft" ? Math.max(0, col - 1) : Math.min(2, col + 1)) as Column;
      setCol(next);
      setRailKeys(next === 0);
      setTuneKeys(next === 2);
      return;
    }
    if (event.key === "Enter") {
      event.preventDefault();
      // A launch-only tab the arrows reached starts its harness on Return, as a click on it does.
      const launchOnly = shownTab?.routes.length === 1 && shown?.launch && !shown.note ? shown : undefined;
      if (launchOnly && (col === 0 || rows.length === 0)) {
        if (families.forkReady === false) return;
        onOpenChange(false);
        families.onLaunch?.(launchOnly.id);
        return;
      }
      if (col === 2 && tuneKeys) runTune(tuneHl);
      else if (col === 1 && focus && !picked) pickModel(hl);
      else if (col === 1 && !focus && !query && shown?.fork && families.forkReady) {
        onOpenChange(false);
        families.onFork?.(shown.id);
        return;
      }
      close();
      return;
    }
    // 1 to 9 on an empty field pick the tab's rows, as in the list menu.
    if ((commandDigit || !query) && /^[1-9]$/.test(event.key)) {
      const index = Number(event.key) - 1;
      if (!rows[index]) return;
      event.preventDefault();
      pickModel(index);
      close();
    }
  };

  // The avatar: the account of the harness whose model the settings column shows (on Starred and in a
  // search too), else the tab's, else the chat's. On the chat's own harness, the chat's route (its
  // account); on another, the route its tab shows. A signed-out harness shows an empty ring and offers
  // sign-in.
  const byId = (id: string | undefined) => (id === undefined ? undefined : list.find((family) => family.id === id));
  // An empty Starred tab shows no model, so no harness owns the corner: a blank person ring.
  const owner =
    (focus && byId(focus.family)) ??
    (shown && !shown.starred ? shown : undefined) ??
    (query ? byId(families.current) : undefined);
  const ownerTab = owner ? tabs.find((entry) => entry.routes.some((route) => route.id === owner.id)) : undefined;
  const routes = ownerTab ? ownerTab.routes : [];
  const onChatTab = owner?.id === families.current;
  const activeAccount = onChatTab
    ? accounts.list?.accounts.find((choice) => choice.id === accounts.list?.active)
    : undefined;
  const signedOut = (!!owner?.note && !!owner.logIn) || (onChatTab && !!auth && canSessionLogin(auth.verdict));
  const authNote = auth ? authText(auth.verdict, t) : undefined;
  // No harness (an empty Starred tab) or one this Mac does not have: no account, so a blank person
  // ring with no badge and no card.
  const avatarShown = !!owner && !owner.setUp;
  const avatarBlank = !avatarShown;
  const routeFace: Face | undefined = routes.length > 1 && owner ? { id: owner.id, name: owner.name } : undefined;
  const face: Face | undefined = signedOut
    ? undefined
    : onChatTab && activeAccount
      ? faceOf(activeAccount, t("picker.harnessLogin"))
      : (routeFace ?? faceOf(undefined, t("picker.harnessLogin")));
  const ownerName = ownerTab?.name ?? owner?.name ?? "";
  const badge = owner?.mark ?? owner?.id;
  const login = t("picker.harnessLogin");
  // A row's detail: what kind of account it is. The harness's own login says nothing more.
  const kindLabel = (kind: string | undefined) =>
    kind === "direct-api-key" ? t("turn.signIn.keyLabel") : isModelRouterKind(kind) ? t("picker.provider") : undefined;
  const faceName = signedOut
    ? t("picker.notSignedIn")
    : onChatTab && activeAccount
      ? activeAccount.name
      : routes.length > 1 && owner
        ? owner.name
        : login;
  const faceDetail = signedOut
    ? t("picker.signInToUse", { harness: ownerName })
    : [onChatTab && activeAccount ? kindLabel(activeAccount.kind) : undefined, ownerName].filter(Boolean).join(" · ");
  const chatChoices = (accounts.list?.accounts ?? []).filter(
    (choice) =>
      choice.kind === "direct-subscription" ||
      choice.kind === "direct-api-key" ||
      isModelRouterKind(choice.kind) ||
      choice.id === accounts.list?.active,
  );
  // Add account… is on every harness's card: the chat's own adds to the family its routes serve,
  // another to its tab's family. A signed-out harness offers an API key instead.
  const appAccounts = useChatAccounts();
  const addAccount = account?.accounts.add ?? appAccounts?.add;
  const addFamily = (onChatTab ? accounts.list?.family : undefined) ?? owner?.accountFamily;
  const canAdd = !!addAccount && !!addFamily;
  const [adding, setAdding] = useState<{ family: string; apiKey: boolean }>();
  const openAdd = () => {
    if (!addFamily) return;
    close();
    setAdding({ family: addFamily, apiKey: signedOut });
    setAddingAccount(true);
  };
  const pickAccount = (routeId: string | null) => {
    close();
    accounts.pick(routeId);
  };
  // The card lists only the accounts the harness is not on: its other routes (transports, logins,
  // launch setups), and on the chat's own harness the chat's other accounts, its CLI login among them.
  type Other = { key: string; face: Face; name: string; detail?: string; disabled?: boolean; pick(): void };
  const others: Other[] = [
    ...(routes.length > 1
      ? routes
          .filter((route) => route.id !== owner?.id)
          .map((route) => ({
            key: `route:${route.id}`,
            face: { id: route.id, name: route.name },
            name: route.name,
            ...(route.note ? { detail: route.note } : {}),
            disabled: !!route.launch && families.forkReady === false,
            pick: () => showRoute(route),
          }))
      : []),
    // A signed-out or expired login still lists the chat's saved accounts: switching is the way out.
    ...(onChatTab && accounts.list
      ? [
          // Back to the default only unbinds the chat; a workspace or family route still applies.
          ...(accounts.list.active
            ? [
                {
                  key: "login",
                  face: faceOf(undefined, login),
                  name: login,
                  disabled: accounts.list.scope !== "chat",
                  pick: () => pickAccount(null),
                },
              ]
            : []),
          ...chatChoices
            .filter((choice) => choice.id !== accounts.list?.active)
            .map((choice) => {
              const detail = kindLabel(choice.kind);
              return {
                key: `account:${choice.id}`,
                face: faceOf(choice, choice.name),
                name: choice.name,
                ...(detail ? { detail } : {}),
                pick: () => pickAccount(choice.id),
              };
            }),
        ]
      : []),
  ];
  const accountsLoading = onChatTab && !!account && !accounts.list;
  const canSignIn = signedOut && (!!owner?.logIn || (onChatTab && !!auth?.onLogin));

  const card = profileOpen && (
    <InlineCard className="acpmux-cols-card" label={`${ownerName} · ${t("picker.account")}`}>
      <div className="acpmux-cols-card-head">
        <Avatar face={face} size={40} {...(badge ? { badge } : {})} />
        <span className="acpmux-cols-card-who">
          <span className="acpmux-cols-card-name">{faceName}</span>
          <span className="acpmux-cols-detail">{faceDetail}</span>
        </span>
      </div>
      {canSignIn && (
        <div className="acpmux-cols-card-cta">
          <button
            type="button"
            className="acpmux-cols-signin"
            onPointerDown={(event) => event.preventDefault()}
            onClick={() => {
              close();
              if (owner?.logIn) owner.logIn();
              else auth?.onLogin?.();
            }}
          >
            {t("picker.signInTo", { harness: ownerName })}
          </button>
        </div>
      )}
      {(others.length > 0 || accountsLoading || accounts.switchFailed) && (
        <>
          <hr className="acpmux-cols-sep" />
          <div className="acpmux-cols-card-list">
            <div className="acpmux-cols-caption">{t("picker.otherAccounts", { harness: ownerName })}</div>
            {onChatTab && accounts.switchFailed && (
              <div className="acpmux-cols-row acpmux-cols-note" aria-disabled="true">
                {t("picker.accountSwitchFailed")}
              </div>
            )}
            {accountsLoading && (
              <div className="acpmux-cols-row acpmux-cols-note" aria-disabled="true">
                {accounts.failed ? t("picker.accountFailed") : "…"}
              </div>
            )}
            {others.map((other) => (
              <DrivenRow
                tabbable
                key={other.key}
                kind="button"
                aria-disabled={other.disabled ? true : undefined}
                className="acpmux-cols-row"
                title={other.detail ? `${other.name} · ${other.detail}` : other.name}
                onPick={() => {
                  if (!other.disabled) other.pick();
                }}
              >
                <Avatar face={other.face} size={20} />
                <span className="acpmux-cols-name">{other.name}</span>
                {other.detail && <span className="acpmux-cols-detail">{other.detail}</span>}
              </DrivenRow>
            ))}
          </div>
        </>
      )}
      {(canAdd || (signedOut && onChatTab && auth?.onRefresh)) && (
        <>
          <hr className="acpmux-cols-sep" />
          <div className="acpmux-cols-card-list">
            {canAdd && (
              <DrivenRow tabbable kind="button" className="acpmux-cols-row acpmux-cols-add" onPick={openAdd}>
                <span className="acpmux-cols-addicon">
                  <PlusIcon />
                </span>
                <span className="acpmux-cols-name">{t(signedOut ? "picker.useApiKey" : "picker.addAccountMore")}</span>
              </DrivenRow>
            )}
            {signedOut && onChatTab && auth?.onRefresh && (
              <DrivenRow tabbable kind="button" className="acpmux-cols-row" onPick={() => auth.onRefresh?.()}>
                <span className="acpmux-cols-name">{t("harnesses.checkAgain")}</span>
              </DrivenRow>
            )}
          </div>
        </>
      )}
    </InlineCard>
  );

  const modelRow = (model: QuickModel, index: number) => {
    const stars = families.stars;
    const starred = stars?.has(model) ?? false;
    const running = isChosen(model);
    return (
      <DrivenRow
        key={`${model.family}\u0000${model.id}`}
        id={`acpmux-cols-model-${index}`}
        kind="option"
        aria-selected={running}
        aria-disabled={model.disabled ? true : undefined}
        className="acpmux-cols-row"
        data-hl={index === hl ? "" : undefined}
        // tooltip-allow: a long model name ends in "…" at the column's width; the tooltip names it whole.
        title={[
          model.name,
          query ? model.harness : undefined,
          model.hint ?? model.provider,
          twins.has(model) ? model.id : undefined,
        ]
          .filter(Boolean)
          .join(" · ")}
        onPick={() => {
          setCol(1);
          pickModel(index);
        }}
      >
        <span className="acpmux-cols-name">{model.name}</span>
        {model.tag && <span className="acpmux-cols-tag">{model.tag}</span>}
        {stars && (
          <button
            type="button"
            className="acpmux-cols-star"
            tabIndex={-1}
            data-on={starred ? "" : undefined}
            aria-pressed={starred}
            aria-label={`${t(starred ? "picker.unstar" : "picker.star")}: ${model.name}`}
            title={t(starred ? "picker.unstar" : "picker.star")}
            onPointerDown={(event) => event.preventDefault()}
            onClick={(event) => {
              event.stopPropagation();
              stars.toggle(model);
            }}
          >
            <StarIcon filled={starred} />
          </button>
        )}
        <span className="acpmux-cols-check">{running && <CheckIcon />}</span>
      </DrivenRow>
    );
  };

  let before = 0;
  const models = groups ? (
    groups.map((group) => {
      const start = before;
      before += group.rows.length;
      return (
        <Fragment key={group.id}>
          <div className="acpmux-cols-group">
            <AgentMark agent={list.find((family) => family.id === group.rows[0]?.family)?.mark} size={12} />
            {group.name}
          </div>
          {group.rows.map((model, offset) => modelRow(model, start + offset))}
        </Fragment>
      );
    })
  ) : (
    <>
      <div className="acpmux-cols-caption">{shown?.starred ? t("picker.starred") : tabName}</div>
      {rows.map((model, index) => (
        <Fragment key={`${model.family}\u0000${model.id}`}>
          {index === legacyFrom && <div className="acpmux-cols-caption">{t("picker.legacyModels")}</div>}
          {modelRow(model, index)}
        </Fragment>
      ))}
    </>
  );

  let tuneIndex = -1;
  const tuneRow = (
    key: string,
    checked: boolean,
    disabled: boolean,
    onClick: () => void,
    body: React.ReactNode,
    kind: "radio" | "switch" = "radio",
  ) => {
    tuneIndex += 1;
    const index = tuneIndex;
    return (
      <DrivenRow
        key={key}
        kind={kind}
        aria-checked={checked}
        aria-disabled={disabled ? true : undefined}
        className="acpmux-cols-row"
        data-hl={col === 2 && index === tuneHl ? "" : undefined}
        onPick={() => {
          if (disabled) return;
          setCol(2);
          setTuneKeys(false);
          setTuneHl(index);
          onClick();
        }}
      >
        {body}
      </DrivenRow>
    );
  };

  const tabEmpty = !query && !!shown && !shown.fork && rows.length === 0;
  return (
    <>
      <button
        ref={(node) => {
          button.current = node;
          trigger.current = node;
        }}
        type="button"
        className="ui-button acpmux-picker-button"
        data-menu={chip["data-menu"]}
        data-popup-open={open ? "" : undefined}
        aria-label={chip.label}
        title={chip.title}
        aria-haspopup="dialog"
        aria-expanded={open}
        {...press}
        // A mouse press never focuses the chip, as the list menu's button: a press that closes the
        // menu and lands a pick leaves the keyboard in the prompt the picker focused.
        onPointerDown={(event) => {
          press.onPointerDown(event);
          if (isMousePress(event)) event.preventDefault();
        }}
        // The closed chip opens on ArrowDown too, as the list menu's did.
        onKeyDown={(event) => {
          if (event.key !== "ArrowDown" || open) return;
          event.preventDefault();
          onOpenChange(true);
        }}
      >
        {children}
      </button>
      <Popover
        open={open}
        onOpenChange={(next, details) => {
          // Escape first closes the account card, then clears a search, then closes the menu.
          if (!next && details?.escape && (profileOpen || query)) {
            if (profileOpen) setProfileOpen(false);
            else {
              setQuery("");
              setModelHl(-1);
              setCol(1);
              setTuneHl(0);
            }
            return;
          }
          finish(next, !!details?.escape);
        }}
        anchor={open ? anchor : null}
        label={t("picker.model")}
        className="acpmux-cols"
        side={side}
        align={align}
        flip={false}
        initialFocus={field}
        finalFocus={false}
      >
        {/* ui-allow: Up, Down, Left, Right and Return move through the columns, as in a column browser. */}
        {/* oxlint-disable-next-line jsx-a11y/no-static-element-interactions -- the field's keys bubble here: arrows move the columns */}
        <div
          ref={frameRef}
          className="acpmux-cols-frame"
          onKeyDown={keyDown}
          // A press anywhere but the avatar and its card closes the card. No press takes the keyboard
          // from the search field (a caption, a note, a gap), except on a column's scroll bar.
          onPointerDown={(event) => {
            const target = event.target as Element;
            if (profileOpen && !target.closest?.(".acpmux-cols-corner")) setProfileOpen(false);
            if (target !== field.current && !target.classList?.contains("acpmux-cols-list")) event.preventDefault();
          }}
        >
          <div className="acpmux-cols-search">
            <span className="acpmux-cols-corner">
              {avatarShown && (
                <button
                  type="button"
                  className="acpmux-cols-profile"
                  aria-haspopup="dialog"
                  aria-expanded={profileOpen}
                  aria-label={`${ownerName} · ${t("picker.account")}: ${faceName}`}
                  title={`${ownerName} · ${faceName}`}
                  onPointerDown={(event) => event.preventDefault()}
                  onClick={() => setProfileOpen((was) => !was)}
                >
                  <Avatar face={face} size={24} {...(badge ? { badge } : {})} />
                </button>
              )}
              {avatarBlank && (
                <span className="acpmux-cols-profile" data-blank="" aria-hidden="true">
                  <Avatar size={24} />
                </span>
              )}
              {card}
            </span>
            <SearchIcon size={14} />
            <input
              ref={fieldRef}
              type="search"
              aria-label={t("picker.search")}
              placeholder={t("picker.search")}
              autoComplete="off"
              spellCheck={false}
              value={query}
              aria-activedescendant={col === 1 && hl >= 0 ? `acpmux-cols-model-${hl}` : undefined}
              onChange={(event) => {
                setQuery(event.target.value);
                setModelHl(event.target.value ? 0 : -1);
                setCol(1);
                setTuneHl(0);
                setProfileOpen(false);
              }}
            />
          </div>
          <hr className="acpmux-cols-sep" />
          {/* The chat's own readiness (an expired login, a route that needs sign-in, an unreachable
              machine), whatever tab or search shows: the avatar is the account, not the readiness. */}
          {auth && authNote && (
            <>
              <div className="acpmux-cols-auth">
                <span>{authNote}</span>
                {canSessionLogin(auth.verdict) && auth.onLogin && (
                  <button
                    type="button"
                    className="acpmux-cols-update-action"
                    onClick={() => {
                      close();
                      auth.onLogin?.();
                    }}
                  >
                    {authLoginText(auth.verdict, t)}
                  </button>
                )}
                {auth.onRefresh && (
                  <button type="button" className="acpmux-cols-update-action" onClick={() => auth.onRefresh?.()}>
                    {t("harnesses.checkAgain")}
                  </button>
                )}
              </div>
              <hr className="acpmux-cols-sep" />
            </>
          )}
          <div ref={bodyRef} className="acpmux-cols-body">
            <DrivenList
              ref={railList}
              kind="tablist"
              label={t("picker.harness")}
              className="acpmux-cols-list acpmux-cols-rail ui-slide-host"
              onScroll={(event) => markFades(event.currentTarget)}
              data-col-focus={col === 0 && railKeys ? "" : undefined}
            >
              <SlidingIndicator selected={!query && shownTab ? shownTab.key : undefined} look="plate" travel="spring" />
              {tabs.map((entry, index) => {
                const family = entry === shownTab && shown ? shown : leadRoute(entry, families.current);
                const selected = !query && entry === shownTab;
                return (
                  <DrivenRow
                    key={entry.key}
                    kind="tab"
                    aria-selected={selected}
                    aria-label={entry.name}
                    aria-disabled={
                      entry.routes.every((route) => route.launch) && families.forkReady === false ? true : undefined
                    }
                    // tooltip-allow: the rail tab draws only the family's mark; the title names it.
                    title={family.note ? `${entry.name} · ${family.note}` : entry.name}
                    className="acpmux-cols-tab ui-slide-item"
                    data-hl={selected ? "" : undefined}
                    data-off={family.setUp ? "" : undefined}
                    onPick={() => {
                      setCol(1);
                      showTab(index);
                    }}
                  >
                    {family.starred ? (
                      <StarIcon filled={selected} />
                    ) : symbolOf(family) ? (
                      <AgentMark agent={family.mark} size={16} />
                    ) : (
                      <span className="acpmux-cols-initial" aria-hidden="true">
                        {initialOf(entry.name)}
                      </span>
                    )}
                  </DrivenRow>
                );
              })}
              {families.onAddHarness && (
                <DrivenRow
                  tabbable
                  kind="button"
                  className="acpmux-cols-tab acpmux-cols-tab-add"
                  aria-label={t("modelPicker.addHarness")}
                  title={t("modelPicker.addHarness")}
                  onPick={() => {
                    close();
                    families.onAddHarness?.();
                  }}
                >
                  <PlusIcon />
                </DrivenRow>
              )}
            </DrivenList>

            <DrivenList
              ref={modelsList}
              kind="listbox"
              label={t("picker.model")}
              className="acpmux-cols-list"
              onScroll={(event) => markFades(event.currentTarget)}
              data-col-focus={col === 1 ? "" : undefined}
            >
              {!query && shown?.fork ? (
                <>
                  <div className="acpmux-cols-caption">{tabName}</div>
                  <DrivenRow
                    kind="button"
                    className="acpmux-cols-row"
                    data-hl=""
                    aria-disabled={!families.forkReady ? true : undefined}
                    onPick={() => {
                      if (!families.forkReady) return;
                      close();
                      families.onFork?.(shown.id);
                    }}
                  >
                    <span className="acpmux-cols-name">{t("picker.forkTo", { harness: shown.name })}</span>
                  </DrivenRow>
                </>
              ) : (
                models
              )}
              {query && rows.length === 0 && (
                <div className="acpmux-cols-row acpmux-cols-note" aria-disabled="true">
                  <span className="acpmux-cols-name">{t("picker.noMatches")}</span>
                </div>
              )}
              {tabEmpty && (
                <div className="acpmux-cols-row acpmux-cols-note" aria-disabled="true">
                  <span className="acpmux-cols-name">
                    {shown.note ?? (shown.starred ? t("picker.starredNone") : t("picker.noModelsYet"))}
                  </span>
                </div>
              )}
              {!query && shown?.note && rows.length > 0 && shown.setUp && (
                <div className="acpmux-cols-row acpmux-cols-note" aria-disabled="true">
                  <span className="acpmux-cols-name">{shown.note}</span>
                </div>
              )}
              {!query && shown?.note && shown.logIn && (
                <DrivenRow
                  kind="button"
                  className="acpmux-cols-row"
                  onPick={() => {
                    close();
                    shown.logIn?.();
                  }}
                >
                  <span className="acpmux-cols-name">{t("harness.logIn")}</span>
                </DrivenRow>
              )}
              {!query && shown?.note && shown.setUp && (
                <DrivenRow
                  kind="button"
                  className="acpmux-cols-row"
                  onPick={() => {
                    close();
                    shown.setUp?.();
                  }}
                >
                  <span className="acpmux-cols-name">{t("harnesses.install")}</span>
                </DrivenRow>
              )}
            </DrivenList>

            <div
              className="acpmux-cols-list acpmux-cols-tune"
              onScroll={(event) => markFades(event.currentTarget)}
              data-col-focus={col === 2 ? "" : undefined}
              aria-label={t("effort.title")}
            >
              {/* The column always heads with Effort. A model with no levels says None, also one whose
                  harness names its levels only once a chat runs it (OpenCode, before a chat). */}
              <div className="acpmux-cols-caption">{t("effort.title")}</div>
              {focus && (
                <>
                  {ladder.length === 0 && (
                    <div className="acpmux-cols-row acpmux-cols-note" aria-disabled="true">
                      <span className="acpmux-cols-name">{t("picker.effortNone")}</span>
                    </div>
                  )}
                  {ladder.map((choice) =>
                    tuneRow(
                      choice.id,
                      levelChosen && choice.id === level,
                      focusOff || !canLandEffort,
                      () => pickLevel(choice.id),
                      <>
                        <span className="acpmux-cols-name">{choice.name}</span>
                        <span className="acpmux-cols-check">{levelChosen && choice.id === level && <CheckIcon />}</span>
                      </>,
                    ),
                  )}
                  {offers.length > 0 && <div className="acpmux-cols-caption">{t("picker.provider")}</div>}
                  {offers.map((offer) =>
                    tuneRow(
                      offer.id,
                      offer === runningOffer,
                      focusOff || !!offer.disabled,
                      () => pickOffer(offer),
                      <>
                        <span className="acpmux-cols-name">{offer.provider}</span>
                        <span className="acpmux-cols-check">{offer === runningOffer && <CheckIcon />}</span>
                      </>,
                    ),
                  )}
                  {fastShown && (
                    <>
                      <div className="acpmux-cols-gap" />
                      {tuneRow(
                        "fast",
                        fastOn,
                        focusOff,
                        toggleFast,
                        <>
                          <span className="acpmux-cols-name">{t("picker.chipFast")}</span>
                          <span className="acpmux-cols-switch" data-on={fastOn ? "" : undefined} aria-hidden="true" />
                        </>,
                        "switch",
                      )}
                    </>
                  )}
                </>
              )}
            </div>
          </div>
          {menu.update && (
            <>
              <hr className="acpmux-cols-sep" />
              <div className="acpmux-cols-update">
                <span>{menu.update.text}</span>
                <button
                  ref={updateAction}
                  type="button"
                  className="acpmux-cols-update-action"
                  onKeyDown={(event) => {
                    if (event.key !== "ArrowUp") return;
                    event.preventDefault();
                    field.current?.focus();
                  }}
                  onClick={() => {
                    menu.update?.run();
                    close();
                  }}
                >
                  {t("harness.update")}
                </button>
              </div>
            </>
          )}
        </div>
      </Popover>
      {addingAccount && addAccount && adding && (
        <AddAccountDialog
          add={addAccount}
          family={adding.family}
          existing={accounts.list?.ids ?? (accounts.list?.accounts ?? []).map((choice) => choice.id)}
          {...(adding.apiKey ? { kinds: ["direct-api-key" as const] } : {})}
          onClose={() => setAddingAccount(false)}
          onAdded={() => {
            setAddingAccount(false);
            onOpenChange(true);
          }}
        />
      )}
    </>
  );
}
