import {
  askText,
  sideQuestionPrompt,
  needsYouModeCapabilities,
  type NeedsYouActions,
  type NeedsYouMode,
} from "../needsYou/ask";
import type { NeedsYouItem } from "../needsYou/model";
import { translate, type Translate } from "../i18n";
import { HEADER_SYMBOLS } from "./headerSymbols";
import type { HeaderQuickTool } from "./headerQuickTools";
import type { HeaderPullRequest } from "./headerState";
import type { PullRequestOps, HeaderOperationAction } from "./pullRequestOps";
import type { WorktreeOps } from "./worktreeOps";
import { pullRequestStatus, checkPresentation } from "./pullRequestOps";
import type { HeaderWorktree } from "./WorktreePill";

export const NATIVE_MAX_TOOLS = 16;
export const NATIVE_MAX_MENU_ITEMS = 32;
export const NATIVE_MAX_TOTAL_MENU_ITEMS = 256;
export const NATIVE_MAX_DEPTH = 2;
export const NATIVE_MAX_TEXT_GRAPHEMES = 64;
export const NATIVE_MAX_TEXT_BYTES = 256;
export const NATIVE_MAX_VISIBLE_TEXT_GRAPHEMES = 32;
export const NATIVE_MAX_VISIBLE_TEXT_BYTES = 128;
export const NATIVE_MAX_URL_BYTES = 2048;

export interface NativeRowTool {
  id: string;
  symbol: string;
  label: string;
  enabled: boolean;
  toggled: boolean;
  badge?: string;
  text?: string;
  menu?: NativeRowMenuItem[];
}
export interface NativeRowMenuItem {
  id: string;
  label: string;
  enabled: boolean;
  checked?: boolean;
  url?: string;
  role?: "destructive";
  children?: NativeRowMenuItem[];
}
export interface NativeRowPanel {
  id: "inspector" | "summary";
  label: string;
  toggled: boolean;
  run?: () => void;
}
export interface NativeRowNeedsYou {
  items: readonly NeedsYouItem[];
  mode: NeedsYouMode;
  actions: NeedsYouActions;
  /// Opt in only when every row action is representable by the native menu. The production
  /// header leaves the pinned editable Ask about this flow in the web popover.
  nativeMenu?: boolean;
  /// Native actions have no DOM row to own the rejection state, so the header feeds it back here.
  failure?: { itemId: string; action: "answer" | "ask"; reason?: string };
  onFailure?: (item: NeedsYouItem, action: "answer" | "ask", error: unknown) => void;
}
export interface NativeRowExtras {
  worktree?: { value: HeaderWorktree; ops: WorktreeOps };
  pullRequest?: { value: HeaderPullRequest; ops: PullRequestOps };
  needsYou?: NativeRowNeedsYou;
}
export interface RowToolBinding {
  tool: NativeRowTool;
  run?: () => void;
  menuRuns?: ReadonlyMap<string, () => void>;
  variableMenu?: NativeRowMenuItem[];
}

const characters = new Intl.Segmenter(undefined, { granularity: "grapheme" });
const encoder = new TextEncoder();

/// Match AgentPaneTabRowTools.swift: non-empty, at most 64 graphemes and 256 UTF-8 bytes.
export function boundedNativeText(value: string, fallback = "…"): string {
  const parts = Array.from(characters.segment(String(value).trim()), (part) => part.segment).slice(
    0,
    NATIVE_MAX_TEXT_GRAPHEMES,
  );
  let result = parts.join("");
  while (result && encoder.encode(result).byteLength > NATIVE_MAX_TEXT_BYTES) {
    parts.pop();
    result = parts.join("");
  }
  if (result) return result;
  const safeFallback =
    Array.from(characters.segment(fallback), (part) => part.segment)
      .slice(0, 1)
      .join("") || "…";
  return encoder.encode(safeFallback).byteLength <= NATIVE_MAX_TEXT_BYTES ? safeFallback : "…";
}
/// Visible text has a tighter budget than accessibility/menu labels. Keep both ends of branch names.
export function nativeVisibleText(value: string, fallback = "…"): string {
  const clean = (value || fallback).replace(/[\r\n\v\f\u0085\u2028\u2029]/g, " ").trim() || "…";
  const parts = Array.from(characters.segment(clean), (part) => part.segment);
  let left = Math.ceil(parts.length / 2),
    right = Math.floor(parts.length / 2);
  if (
    parts.length <= NATIVE_MAX_VISIBLE_TEXT_GRAPHEMES &&
    encoder.encode(clean).byteLength <= NATIVE_MAX_VISIBLE_TEXT_BYTES
  )
    return clean;
  let result = "";
  do {
    if (left >= right) left--;
    else right--;
    result = parts.slice(0, left).join("") + "…" + (right ? parts.slice(-right).join("") : "");
  } while (
    left + right + 1 > NATIVE_MAX_VISIBLE_TEXT_GRAPHEMES ||
    encoder.encode(result).byteLength > NATIVE_MAX_VISIBLE_TEXT_BYTES
  );
  return result;
}
/// The host owns navigation; omit unsupported links rather than sending a descriptor it refuses.
function nativeMenuURL(value: string | undefined): string | undefined {
  if (!value || encoder.encode(value).byteLength > NATIVE_MAX_URL_BYTES) return;
  try {
    const url = new URL(value);
    if (
      (url.protocol === "http:" || url.protocol === "https:") &&
      encoder.encode(url.href).byteLength <= NATIVE_MAX_URL_BYTES
    )
      return url.href;
  } catch {
    // Invalid URL: keep the row as information, without a link action.
  }
}
type NativeMenuKey = (value: string) => string;
let nextMenuKey = 0n;
/// One hook owns a scope. Exact values keep their IDs across unchanged renders; values absent
/// from the next build are forgotten. The page-wide counter never reuses a retired ID, including
/// across unmounts. Only the current descriptor inputs are retained, not a history of targets.
export function createNativeMenuKeys(): () => NativeMenuKey {
  let previous = new Map<string, string>();
  return () => {
    const prior = previous;
    const current = new Map<string, string>();
    previous = current;
    return (value) => {
      const id = current.get(value) ?? prior.get(value) ?? (++nextMenuKey).toString(36);
      current.set(value, id);
      return id;
    };
  };
}
const menuLabel = (label: string, fallback = "…") => boundedNativeText(label, fallback);
function menuCost(item: NativeRowMenuItem): number {
  return 1 + (item.children?.reduce((sum, child) => sum + menuCost(child), 0) ?? 0);
}
function moreItem(id: string, count: number): NativeRowMenuItem {
  return { id, label: `+${count} more`, enabled: false };
}
/// Fit whole variable rows, reserving the summary slot before adding any of them.
function fitVariable(items: NativeRowMenuItem[], slots: number, budget: number, id: string): NativeRowMenuItem[] {
  const total = items.reduce((sum, item) => sum + menuCost(item), 0);
  if (items.length <= slots && total <= budget) return items;
  const kept: NativeRowMenuItem[] = [];
  let spent = 0;
  for (const item of items) {
    const cost = menuCost(item);
    if (kept.length >= slots - 1 || spent + cost > budget - 1) break;
    kept.push(item);
    spent += cost;
  }
  if (slots > 0 && budget > 0) kept.push(moreItem(id, items.length - kept.length));
  return kept;
}
/// Reserve fixed operation rows across every tool before spending the remaining aggregate budget
/// on checks or asks. These variable lists can never displace Merge, Apply or Remove.
function fitMenus(bindings: RowToolBinding[]): RowToolBinding[] {
  let remaining =
    NATIVE_MAX_TOTAL_MENU_ITEMS -
    bindings.reduce((sum, { tool }) => sum + (tool.menu?.reduce((n, item) => n + menuCost(item), 0) ?? 0), 0);
  let lists = bindings.filter((binding) => binding.variableMenu?.length).length;
  return bindings.map(({ variableMenu, ...binding }) => {
    if (!variableMenu?.length) return binding;
    lists--;
    const fixed = binding.tool.menu ?? [];
    const variable = fitVariable(
      variableMenu,
      NATIVE_MAX_MENU_ITEMS - fixed.length,
      remaining - lists,
      `more:${binding.tool.id}`,
    );
    remaining -= variable.reduce((sum, item) => sum + menuCost(item), 0);
    return { ...binding, tool: { ...binding.tool, menu: [...fixed, ...variable] } };
  });
}
function addAction(
  menu: NativeRowMenuItem[],
  runs: Map<string, () => void>,
  id: string,
  action?: HeaderOperationAction,
) {
  if (!action) return;
  menu.push({ id, label: menuLabel(action.label), enabled: action.enabled });
  runs.set(id, action.run);
}
function addMessages(menu: NativeRowMenuItem[], prefix: string, messages: string[]) {
  messages.forEach((message, index) =>
    menu.push({ id: `${prefix}.message:${index}`, label: menuLabel(message), enabled: false }),
  );
}
function worktreeBinding(
  extra: NonNullable<NativeRowExtras["worktree"]>,
  t: Translate,
  key: NativeMenuKey,
): RowToolBinding {
  const { value, ops } = extra;
  const identity = key(ops.identity || "worktree");
  const menu: NativeRowMenuItem[] = [],
    runs = new Map<string, () => void>();
  // Like the DOM popover, a new chat still opens the worktree facts before mutations are available.
  const detail = value.base
    ? t("header.worktreeFrom", { main: value.mainRoot, base: value.base })
    : t("header.worktreeOf", { main: value.mainRoot });
  addMessages(menu, "worktree.facts", [value.branch, detail]);
  addAction(menu, runs, `worktree.apply:${identity}`, ops.apply);
  addAction(menu, runs, `worktree.${ops.keep ? "removeAnyway" : "remove"}:${identity}`, ops.remove);
  addAction(menu, runs, `worktree.keep:${identity}`, ops.keep);
  addMessages(menu, "worktree", ops.messages);
  return {
    tool: {
      id: "worktree",
      symbol: HEADER_SYMBOLS["git.worktree"]!,
      label: boundedNativeText(value.branch, "Worktree"),
      text: nativeVisibleText(value.branch, "Worktree"),
      enabled: true,
      toggled: false,
      menu,
    },
    menuRuns: runs,
  };
}
function pullRequestBinding(
  extra: NonNullable<NativeRowExtras["pullRequest"]>,
  t: Translate,
  key: NativeMenuKey,
): RowToolBinding {
  const { value, ops } = extra;
  const identity = key(ops.identity || "pullRequest");
  const revision = key(JSON.stringify(value.checkList));
  const menu: NativeRowMenuItem[] = [],
    runs = new Map<string, () => void>();
  const openId = `pullRequest.open:${identity}`;
  const url = nativeMenuURL(value.url);
  menu.push({
    id: openId,
    label: menuLabel(value.title || `#${value.number}`),
    enabled: !!url,
    ...(url ? { url } : {}),
  });
  addAction(menu, runs, `pullRequest.merge:${identity}`, ops.start);
  addAction(menu, runs, `pullRequest.confirm:${identity}`, ops.confirm);
  addAction(menu, runs, `pullRequest.cancel:${identity}`, ops.cancel);
  addMessages(menu, "pullRequest", ops.question ? [ops.question, ...ops.messages] : ops.messages);
  const variableMenu = value.checkList.map((check, index) => {
    const id = `pullRequest.check:${identity}:${revision}:${index}`;
    const url = nativeMenuURL(check.url);
    return { id, label: menuLabel(checkPresentation(check, t)), enabled: !!url, ...(url ? { url } : {}) };
  });
  const status = pullRequestStatus(value, t);
  return {
    tool: {
      id: "pullRequest",
      symbol: HEADER_SYMBOLS["git.pullrequest"]!,
      label: boundedNativeText(status.label),
      text: nativeVisibleText(status.badge),
      enabled: true,
      toggled: value.state === "open",
      menu,
    },
    menuRuns: runs,
    variableMenu,
  };
}
function needsYouBinding(extra: NativeRowNeedsYou, t: Translate, key: NativeMenuKey): RowToolBinding | undefined {
  if (extra.mode === "off") return undefined;
  const capabilities = needsYouModeCapabilities(extra.mode);
  const runs = new Map<string, () => void>();
  const revision = key(JSON.stringify([extra.mode, extra.items]));
  const menu = extra.items.map((item, itemIndex) => {
    const itemKey = `${revision}:${itemIndex}`,
      children: NativeRowMenuItem[] = [];
    for (const [choiceIndex, choice] of (capabilities.answers ? item.answers : []).entries()) {
      const id = `needsYou:${itemKey}:answer:${choiceIndex}`;
      children.push({
        id,
        label: menuLabel(
          choice.id === "resume" && item.kind === "held" ? (t?.("needsYou.resume") ?? "Resume") : choice.label,
        ),
        enabled: true,
      });
      runs.set(
        id,
        () => void extra.actions.answer(item, choice).catch((error) => extra.onFailure?.(item, "answer", error)),
      );
    }
    const goId = `needsYou:${itemKey}:goToSource`;
    children.push({ id: goId, label: menuLabel(t?.("needsYou.goToSource") ?? "Go to source"), enabled: true });
    runs.set(goId, () => extra.actions.goTo(item));
    if (capabilities.askAbout) {
      const askId = `needsYou:${itemKey}:askAbout`;
      children.push({ id: askId, label: menuLabel(t?.("needsYou.askAbout") ?? "Ask about this"), enabled: true });
      runs.set(
        askId,
        () =>
          void extra.actions
            .ask(item, sideQuestionPrompt(item, t?.("needsYou.askSeed") ?? "What is going on here?"))
            .catch((error) => extra.onFailure?.(item, "ask", error)),
      );
    }
    if (extra.failure?.itemId === item.id) {
      const label = extra.failure.reason
        ? extra.failure.reason
        : extra.failure.action === "ask"
          ? (t?.("needsYou.askFailed") ?? "Ask failed")
          : (t?.("needsYou.answerFailed") ?? "Answer failed");
      children.push({ id: `needsYou:${itemKey}:failure`, label: menuLabel(label), enabled: false });
    }
    return {
      id: `needsYou:${itemKey}`,
      label: menuLabel(
        [
          askText(item, t ?? ((key) => key)),
          item.who.chief ? t?.("needsYou.chief") : item.who.name,
          capabilities.detail && item.detail ? item.detail : undefined,
        ]
          .filter(Boolean)
          .join(" · "),
      ),
      enabled: true,
      children: fitVariable(children, NATIVE_MAX_MENU_ITEMS, NATIVE_MAX_TOTAL_MENU_ITEMS, `more:${itemKey}`),
    };
  });
  return {
    tool: {
      id: "needsYou",
      symbol: HEADER_SYMBOLS.inbox!,
      label: boundedNativeText(t?.("needsYou.title") ?? "Needs you", "Needs you"),
      enabled: true,
      toggled: false,
      badge: boundedNativeText(String(extra.items.length), "0"),
      menu: menu.length
        ? []
        : [
            {
              id: "needsYou.empty",
              label: menuLabel(t?.("needsYou.empty") ?? "Nothing needs you right now"),
              enabled: false,
            },
          ],
    },
    menuRuns: runs,
    variableMenu: menu,
  };
}
export function nativeRowToolBindings(
  quick: readonly HeaderQuickTool[],
  panel?: NativeRowPanel,
  extras?: NativeRowExtras,
  t: Translate = translate,
  menuKeys = createNativeMenuKeys(),
): RowToolBinding[] {
  const key = menuKeys();
  const bindings: RowToolBinding[] = [
    ...(extras?.worktree ? [worktreeBinding(extras.worktree, t, key)] : []),
    ...(extras?.pullRequest ? [pullRequestBinding(extras.pullRequest, t, key)] : []),
    ...(panel
      ? [
          {
            tool: {
              id: panel.id,
              symbol: HEADER_SYMBOLS["view.list"]!,
              label: boundedNativeText(panel.label, "Panel"),
              enabled: !!panel.run,
              toggled: panel.toggled,
            },
            run: panel.run,
          },
        ]
      : []),
    ...(extras?.needsYou?.nativeMenu
      ? [needsYouBinding(extras.needsYou, t, key)].filter((binding): binding is RowToolBinding => binding !== undefined)
      : []),
    ...quick.map(({ id, icon, label, pressed, run }) => ({
      tool: {
        id,
        symbol: HEADER_SYMBOLS[icon]!,
        label: boundedNativeText(label, id),
        enabled: !!run,
        toggled: pressed === true,
      },
      run,
    })),
  ];
  return fitMenus(bindings.slice(0, NATIVE_MAX_TOOLS));
}
export function dispatchNativeRowTool(value: unknown, bindings: readonly RowToolBinding[]): void {
  if (!value || typeof value !== "object") return;
  const event = value as { id?: unknown; menuItemId?: unknown };
  if (typeof event.id !== "string") return;
  const binding = bindings.find(({ tool }) => tool.id === event.id);
  if (!binding?.tool.enabled) return;
  if (event.menuItemId !== undefined) {
    if (typeof event.menuItemId !== "string") return;
    const menu = binding.tool.menu ?? [];
    const item =
      menu.find((entry) => entry.id === event.menuItemId) ??
      menu.flatMap((entry) => entry.children ?? []).find((entry) => entry.id === event.menuItemId);
    if (!item || !item.enabled) return;
    binding.menuRuns?.get(event.menuItemId)?.();
    return;
  }
  if (binding.tool.menu?.length) return;
  binding.run?.();
}
const listeners = new Set<(value: unknown) => void>();
export function receiveNativeRowToolInvocation(value: unknown): void {
  for (const listener of listeners) listener(value);
}
export function onNativeRowToolInvocation(listener: (value: unknown) => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}
