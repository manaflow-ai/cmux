import { askText, sideQuestionPrompt, type NeedsYouActions, type NeedsYouMode } from "../needsYou/NeedsYou";
import type { NeedsYouItem } from "../needsYou/model";
import type { Translate } from "../i18n";
import { HEADER_SYMBOLS } from "./headerSymbols";
import type { HeaderQuickTool } from "./headerQuickTools";
import type { HeaderPullRequest, HeaderCheck } from "./headerState";
import { readyToMerge } from "./PullRequestMerge";
import type { HeaderWorktree } from "./WorktreePill";

export const NATIVE_MAX_TOOLS = 16;
export const NATIVE_MAX_MENU_ITEMS = 32;
export const NATIVE_MAX_TOTAL_MENU_ITEMS = 256;
export const NATIVE_MAX_DEPTH = 2;
export const NATIVE_MAX_TEXT_GRAPHEMES = 64;
export const NATIVE_MAX_TEXT_BYTES = 256;

export interface NativeRowTool {
  id: string;
  symbol: string;
  label: string;
  enabled: boolean;
  toggled: boolean;
  badge?: string;
  menu?: NativeRowMenuItem[];
}
export interface NativeRowMenuItem {
  id: string;
  label: string;
  enabled: boolean;
  checked?: boolean;
  role?: "destructive";
  children?: NativeRowMenuItem[];
}
export interface NativeRowPanel {
  id: "inspector" | "summary";
  label: string;
  toggled: boolean;
  run?: () => void;
}
export type NativeOperationState =
  | { step: "idle"; key?: string }
  | { step: "pending"; key: string; discard?: boolean }
  | { step: "confirm" }
  | { step: "failed"; key?: string; discard?: boolean; message?: string; unsaved?: boolean }
  | { step: "success" };
export interface NativeRowNeedsYou {
  items: readonly NeedsYouItem[];
  mode: NeedsYouMode;
  actions: NeedsYouActions;
}
export interface NativeRowExtras {
  worktree?: {
    value: HeaderWorktree;
    identity?: string;
    onApply?: (key: string) => Promise<unknown>;
    onRemove?: (key: string, discard: boolean) => Promise<unknown>;
    applyState?: NativeOperationState;
    removeState?: NativeOperationState;
    onApplyStart?: (key: string) => void;
    onApplyEnd?: (state: NativeOperationState) => void;
    onRemoveStart?: (key: string, discard: boolean) => void;
    onRemoveEnd?: (state: NativeOperationState) => void;
    removeUnsaved?: boolean;
    onRemoveKeep?: () => void;
  };
  pullRequest?: {
    value: HeaderPullRequest;
    mergeState?: NativeOperationState;
    onMerge?: (pullRequest: { number: number; url: string }) => Promise<{ queued: boolean }>;
    onMergeConfirm?: () => void;
    onMergeStart?: () => void;
    onMergeEnd?: (state: NativeOperationState) => void;
  };
  needsYou?: NativeRowNeedsYou;
}
export interface RowToolBinding {
  tool: NativeRowTool;
  run?: () => void;
  menuRuns?: ReadonlyMap<string, () => void>;
}

const characters = new Intl.Segmenter(undefined, { granularity: "grapheme" });
const encoder = new TextEncoder();
const actionKey = () => globalThis.crypto?.randomUUID?.() ?? `native-${Date.now()}-${Math.random()}`;

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
function middleBounded(value: string, fallback = "…"): string {
  const parts = Array.from(characters.segment(String(value).trim()), (part) => part.segment);
  if (parts.length <= NATIVE_MAX_TEXT_GRAPHEMES && encoder.encode(value).byteLength <= NATIVE_MAX_TEXT_BYTES)
    return value;
  const keep = Math.max(1, NATIVE_MAX_TEXT_GRAPHEMES - 1);
  const left = Math.ceil(keep / 2),
    right = Math.floor(keep / 2);
  return boundedNativeText(`${parts.slice(0, left).join("")}…${parts.slice(-right).join("")}`, fallback);
}
const stableMenuKey = (value: string): string => {
  let hash = 2166136261;
  for (let index = 0; index < value.length; index += 1) {
    hash ^= value.charCodeAt(index);
    hash = Math.imul(hash, 16777619);
  }
  return (hash >>> 0).toString(36);
};
const identityKey = (value: string, fallback: string) => stableMenuKey(value || fallback);
const menuLabel = (label: string, fallback = "…") => boundedNativeText(label, fallback);
function boundedMenu(items: readonly NativeRowMenuItem[]): NativeRowMenuItem[] {
  return items.slice(0, NATIVE_MAX_MENU_ITEMS).map((item) => ({
    ...item,
    id: boundedNativeText(item.id, "item"),
    label: menuLabel(item.label),
    ...(item.children ? { children: boundedMenu(item.children) } : {}),
  }));
}
function menuCost(item: NativeRowMenuItem): number {
  return 1 + (item.children?.reduce((sum, child) => sum + menuCost(child), 0) ?? 0);
}
/// The native decoder counts every nested row against one 256-item budget. Drop whole rows and leave a disabled summary.
function fitMenus(bindings: RowToolBinding[]): RowToolBinding[] {
  let remaining = NATIVE_MAX_TOTAL_MENU_ITEMS;
  return bindings.map((binding, bindingIndex) => {
    if (!binding.tool.menu) return binding;
    const source = boundedMenu(binding.tool.menu),
      kept: NativeRowMenuItem[] = [];
    let dropped = Math.max(0, binding.tool.menu.length - source.length);
    for (const item of source) {
      const cost = menuCost(item);
      if (cost <= remaining && kept.length < NATIVE_MAX_MENU_ITEMS) {
        kept.push(item);
        remaining -= cost;
      } else dropped += 1;
    }
    if (dropped > 0 && remaining > 0) {
      if (kept.length >= NATIVE_MAX_MENU_ITEMS) {
        kept.pop();
        remaining += 1;
      }
      kept.push({
        id: `native.more:${bindingIndex}:${stableMenuKey(String(dropped))}`,
        label: `+${dropped} more`,
        enabled: false,
      });
      remaining -= 1;
    }
    return { ...binding, tool: { ...binding.tool, menu: kept } };
  });
}

function worktreeBinding(extra: NonNullable<NativeRowExtras["worktree"]>, t?: Translate): RowToolBinding {
  const identity = identityKey(`${extra.identity ?? extra.value.mainRoot}\u0000${extra.value.branch}`, "worktree");
  const menu: NativeRowMenuItem[] = [],
    runs = new Map<string, () => void>();
  const apply = extra.applyState ?? { step: "idle" as const };
  const remove =
    extra.removeState ??
    (extra.removeUnsaved ? { step: "failed" as const, discard: false } : { step: "idle" as const });
  const applyId = `worktree.apply:${identity}`;
  if (extra.onApply) {
    const key = apply.step === "failed" && apply.key ? apply.key : actionKey();
    menu.push({
      id: applyId,
      label: menuLabel(
        apply.step === "pending" ? "Applying…" : (t?.("header.worktreeApply") ?? "Apply to main checkout"),
      ),
      enabled: apply.step !== "pending",
    });
    if (apply.step !== "pending")
      runs.set(applyId, () => {
        extra.onApplyStart?.(key);
        void extra.onApply!(key).then(
          () => extra.onApplyEnd?.({ step: "success" }),
          (error) =>
            extra.onApplyEnd?.({ step: "failed", key, message: error instanceof Error ? error.message : undefined }),
        );
      });
  }
  const removeId = `worktree.remove:${identity}`,
    discardId = `worktree.removeAnyway:${identity}`;
  if (extra.onRemove && !extra.removeUnsaved && remove.step !== "failed") {
    const key = actionKey();
    menu.push({
      id: removeId,
      label: menuLabel(remove.step === "pending" ? "Removing…" : (t?.("header.worktreeRemove") ?? "Remove worktree")),
      enabled: remove.step !== "pending",
    });
    if (remove.step !== "pending")
      runs.set(removeId, () => {
        extra.onRemoveStart?.(key, false);
        void extra.onRemove!(key, false).then(
          () => extra.onRemoveEnd?.({ step: "success" }),
          (error) =>
            extra.onRemoveEnd?.({
              step: "failed",
              key,
              discard: false,
              message: error instanceof Error ? error.message : undefined,
            }),
        );
      });
  }
  if (
    extra.onRemove &&
    (extra.removeUnsaved || (remove.step === "failed" && (remove.discard === false || remove.discard === true)))
  ) {
    const key = remove.step === "failed" && remove.key ? remove.key : actionKey();
    menu.push({
      id: discardId,
      label: menuLabel(t?.("header.worktreeRemoveAnyway") ?? "Remove anyway"),
      enabled: remove.step !== "pending",
    });
    if (remove.step !== "pending")
      runs.set(discardId, () => {
        extra.onRemoveStart?.(key, true);
        void extra.onRemove!(key, true).then(
          () => extra.onRemoveEnd?.({ step: "success" }),
          (error) =>
            extra.onRemoveEnd?.({
              step: "failed",
              key,
              discard: true,
              message: error instanceof Error ? error.message : undefined,
            }),
        );
      });
    if (extra.onRemoveKeep) {
      const keepId = `worktree.removeKeep:${identity}`;
      menu.push({ id: keepId, label: menuLabel(t?.("header.worktreeRemoveKeep") ?? "Keep"), enabled: true });
      runs.set(keepId, extra.onRemoveKeep);
    }
  }
  return {
    tool: {
      id: "worktree",
      symbol: HEADER_SYMBOLS["git.worktree"]!,
      label: boundedNativeText(extra.value.branch, "worktree"),
      badge: middleBounded(extra.value.branch, "worktree"),
      enabled: true,
      toggled: false,
      ...(menu.length ? { menu } : {}),
    },
    ...(menu.length ? { menuRuns: runs } : {}),
  };
}
function checkLabel(check: HeaderCheck): string {
  return `${check.state === "failed" ? "✕" : check.state === "pending" ? "…" : "✓"} ${check.name}`;
}
function pullRequestBinding(extra: NonNullable<NativeRowExtras["pullRequest"]>, t?: Translate): RowToolBinding {
  const { value } = extra,
    identity = identityKey(`${value.url}\u0000${value.number}`, "pullRequest");
  const mergeable = extra.onMerge !== undefined && readyToMerge(value),
    menu: NativeRowMenuItem[] = [],
    runs = new Map<string, () => void>();
  const openId = `pullRequest.open:${identity}`;
  menu.push({ id: openId, label: "Open pull request", enabled: true });
  runs.set(openId, () => {
    if (typeof window !== "undefined") window.open(value.url, "_blank", "noopener,noreferrer");
  });
  for (const [index, check] of value.checkList.entries()) {
    const id = `pullRequest.check:${identity}:${stableMenuKey(`${check.name}\u0000${check.url ?? index}`)}`;
    menu.push({ id, label: menuLabel(checkLabel(check)), enabled: !!check.url });
    if (check.url) runs.set(id, () => window.open(check.url!, "_blank", "noopener,noreferrer"));
  }
  const mergeId = `pullRequest.merge:${identity}`,
    merge = extra.mergeState ?? { step: "idle" as const },
    mergeEnabled = merge.step === "idle" || merge.step === "confirm" || merge.step === "failed";
  menu.push({
    id: mergeId,
    label: menuLabel(
      merge.step === "confirm"
        ? "Confirm merge"
        : merge.step === "pending"
          ? "Merging…"
          : (t?.("header.prMerge") ?? "Merge"),
    ),
    enabled: mergeEnabled && mergeable,
  });
  if (mergeEnabled && mergeable)
    runs.set(mergeId, () => {
      if (merge.step === "idle" || merge.step === "failed") {
        extra.onMergeConfirm?.();
        return;
      }
      if (merge.step !== "confirm") return;
      extra.onMergeStart?.();
      void extra.onMerge?.({ number: value.number, url: value.url }).then(
        (result) => extra.onMergeEnd?.({ step: result.queued ? "success" : "success" }),
        (error) => extra.onMergeEnd?.({ step: "failed", message: error instanceof Error ? error.message : undefined }),
      );
    });
  const failed = value.checkList.filter((check) => check.state === "failed").length;
  const badge =
    value.checks.total === 0
      ? `#${value.number}`
      : failed > 0
        ? `#${value.number} ✕${failed}`
        : `#${value.number} ✓${value.checks.passed}/${value.checks.total}`;
  return {
    tool: {
      id: "pullRequest",
      symbol: HEADER_SYMBOLS["git.pullrequest"]!,
      label: boundedNativeText(
        t?.("header.pullRequestLabel", { number: value.number, state: value.state }) ?? `Pull request #${value.number}`,
      ),
      enabled: true,
      toggled: value.state === "open",
      badge: boundedNativeText(badge, `#${value.number}`),
      menu,
    },
    menuRuns: runs,
  };
}
function needsYouBinding(extra: NativeRowNeedsYou, t?: Translate): RowToolBinding | undefined {
  if (extra.mode === "off") return undefined;
  const runs = new Map<string, () => void>();
  const menu = extra.items.slice(0, NATIVE_MAX_MENU_ITEMS).map((item) => {
    const itemKey = stableMenuKey(item.id),
      children: NativeRowMenuItem[] = [];
    for (const choice of item.answers) {
      const id = `needsYou:${itemKey}:answer:${stableMenuKey(choice.id)}`;
      children.push({
        id,
        label: menuLabel(
          choice.id === "resume" && item.kind === "held" ? (t?.("needsYou.resume") ?? "Resume") : choice.label,
        ),
        enabled: true,
      });
      runs.set(id, () => void extra.actions.answer(item, choice).catch(() => undefined));
    }
    const goId = `needsYou:${itemKey}:goToSource`;
    children.push({ id: goId, label: menuLabel(t?.("needsYou.goToSource") ?? "Go to source"), enabled: true });
    runs.set(goId, () => extra.actions.goTo(item));
    const askId = `needsYou:${itemKey}:askAbout`;
    children.push({ id: askId, label: menuLabel(t?.("needsYou.askAbout") ?? "Ask about this"), enabled: true });
    runs.set(
      askId,
      () =>
        void extra.actions
          .ask(item, sideQuestionPrompt(item, t?.("needsYou.askSeed") ?? "What is going on here?"))
          .catch(() => undefined),
    );
    return { id: `needsYou:${itemKey}`, label: menuLabel(askText(item, t ?? ((key) => key))), enabled: true, children };
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
        ? menu
        : [
            {
              id: "needsYou.empty",
              label: menuLabel(t?.("needsYou.empty") ?? "Nothing needs you right now"),
              enabled: false,
            },
          ],
    },
    menuRuns: runs,
  };
}
export function nativeRowToolBindings(
  quick: readonly HeaderQuickTool[],
  panel?: NativeRowPanel,
  extras?: NativeRowExtras,
  t?: Translate,
): RowToolBinding[] {
  const bindings: RowToolBinding[] = [
    ...(extras?.worktree ? [worktreeBinding(extras.worktree, t)] : []),
    ...(extras?.pullRequest ? [pullRequestBinding(extras.pullRequest, t)] : []),
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
    ...(extras?.needsYou
      ? [needsYouBinding(extras.needsYou, t)].filter((binding): binding is RowToolBinding => binding !== undefined)
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
