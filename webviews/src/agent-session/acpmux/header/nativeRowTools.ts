import { askText, sideQuestionPrompt, type NeedsYouActions, type NeedsYouMode } from "../needsYou/NeedsYou";
import type { NeedsYouItem } from "../needsYou/model";
import type { Translate } from "../i18n";
import { HEADER_SYMBOLS } from "./headerSymbols";
import type { HeaderQuickTool } from "./headerQuickTools";
import type { HeaderPullRequest } from "./headerState";
import { readyToMerge } from "./PullRequestMerge";
import type { HeaderWorktree } from "./WorktreePill";

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
export interface NativeRowNeedsYou {
  items: readonly NeedsYouItem[];
  mode: NeedsYouMode;
  actions: NeedsYouActions;
}
export interface NativeRowExtras {
  worktree?: {
    value: HeaderWorktree;
    onApply?: (key: string) => Promise<unknown>;
    onRemove?: (key: string, discard: boolean) => Promise<unknown>;
  };
  pullRequest?: {
    value: HeaderPullRequest;
    onMerge?: (pullRequest: { number: number; url: string }) => Promise<{ queued: boolean }>;
  };
  needsYou?: NativeRowNeedsYou;
}
export interface RowToolBinding {
  tool: NativeRowTool;
  run?: () => void;
  menuRuns?: ReadonlyMap<string, () => void>;
}

const characters = new Intl.Segmenter(undefined, { granularity: "grapheme" });
const boundedLabel = (label: string) =>
  label.length <= 64
    ? label
    : Array.from(characters.segment(label))
        .slice(0, 64)
        .map((part) => part.segment)
        .join("");
const actionKey = () => globalThis.crypto?.randomUUID?.() ?? `native-${Date.now()}-${Math.random()}`;
const menuLabel = (label: string) => boundedLabel(label);

function boundedMenu(items: readonly NativeRowMenuItem[]): NativeRowMenuItem[] {
  return items.slice(0, 32).map((item) => ({
    ...item,
    label: menuLabel(item.label),
    ...(item.children ? { children: boundedMenu(item.children) } : {}),
  }));
}

function worktreeBinding(extra: NonNullable<NativeRowExtras["worktree"]>, t?: Translate): RowToolBinding {
  const menu: NativeRowMenuItem[] = [];
  const runs = new Map<string, () => void>();
  if (extra.onApply) {
    menu.push({
      id: "worktree.apply",
      label: menuLabel(t?.("header.worktreeApply") ?? "Apply to main checkout"),
      enabled: true,
    });
    runs.set("worktree.apply", () => void extra.onApply!(actionKey()));
  }
  if (extra.onRemove) {
    menu.push({
      id: "worktree.remove",
      label: menuLabel(t?.("header.worktreeRemove") ?? "Remove worktree"),
      enabled: true,
    });
    runs.set("worktree.remove", () => void extra.onRemove!(actionKey(), false));
  }
  return {
    tool: {
      id: "worktree",
      symbol: HEADER_SYMBOLS["git.worktree"]!,
      label: extra.value.branch,
      enabled: true,
      toggled: false,
      ...(menu.length ? { menu } : {}),
    },
    ...(menu.length ? { menuRuns: runs } : {}),
  };
}

function pullRequestBinding(extra: NonNullable<NativeRowExtras["pullRequest"]>, t?: Translate): RowToolBinding {
  const { value } = extra;
  const mergeable = extra.onMerge !== undefined && readyToMerge(value);
  return {
    tool: {
      id: "pullRequest",
      symbol: HEADER_SYMBOLS["git.pullrequest"]!,
      label:
        t?.("header.pullRequestLabel", { number: value.number, state: value.state }) ?? `Pull request #${value.number}`,
      enabled: true,
      toggled: value.state === "open",
      badge: `#${value.number}`,
      menu: [{ id: "pullRequest.merge", label: menuLabel(t?.("header.prMerge") ?? "Merge"), enabled: mergeable }],
    },
    menuRuns: mergeable
      ? new Map([["pullRequest.merge", () => void extra.onMerge!({ number: value.number, url: value.url })]])
      : new Map(),
  };
}

function needsYouBinding(extra: NativeRowNeedsYou, t?: Translate): RowToolBinding | undefined {
  if (extra.mode === "off") return undefined;
  const runs = new Map<string, () => void>();
  const menu = extra.items.slice(0, 32).map((item) => {
    const children: NativeRowMenuItem[] = [];
    for (const choice of item.answers) {
      const id = `needsYou:${item.id}:answer:${choice.id}`;
      children.push({
        id,
        label: menuLabel(
          choice.id === "resume" && item.kind === "held" ? (t?.("needsYou.resume") ?? "Resume") : choice.label,
        ),
        enabled: true,
      });
      runs.set(id, () => void extra.actions.answer(item, choice).catch(() => undefined));
    }
    const goId = `needsYou:${item.id}:goToSource`;
    children.push({ id: goId, label: menuLabel(t?.("needsYou.goToSource") ?? "Go to source"), enabled: true });
    runs.set(goId, () => extra.actions.goTo(item));
    const askId = `needsYou:${item.id}:askAbout`;
    children.push({ id: askId, label: menuLabel(t?.("needsYou.askAbout") ?? "Ask about this"), enabled: true });
    runs.set(
      askId,
      () =>
        void extra.actions
          .ask(item, sideQuestionPrompt(item, t?.("needsYou.askSeed") ?? "What is going on here?"))
          .catch(() => undefined),
    );
    return {
      id: `needsYou:${item.id}`,
      label: menuLabel(askText(item, t ?? ((key) => key))),
      enabled: true,
      children,
    };
  });
  return {
    tool: {
      id: "needsYou",
      symbol: HEADER_SYMBOLS.inbox!,
      label: t?.("needsYou.title") ?? "Needs you",
      enabled: true,
      toggled: false,
      ...(extra.items.length > 0
        ? { badge: String(extra.items.length), menu: boundedMenu(menu) }
        : {
            menu: [
              {
                id: "needsYou.empty",
                label: menuLabel(t?.("needsYou.empty") ?? "Nothing needs you right now"),
                enabled: false,
              },
            ],
          }),
    },
    ...(runs.size ? { menuRuns: runs } : {}),
  };
}

/// The declarative descriptors and one dispatch table are shared by native and DOM controls.
export function nativeRowToolBindings(
  quick: readonly HeaderQuickTool[],
  panel?: NativeRowPanel,
  extras?: NativeRowExtras,
  t?: Translate,
): RowToolBinding[] {
  return [
    ...(extras?.worktree ? [worktreeBinding(extras.worktree, t)] : []),
    ...(extras?.pullRequest ? [pullRequestBinding(extras.pullRequest, t)] : []),
    ...(panel
      ? [
          {
            tool: {
              id: panel.id,
              symbol: HEADER_SYMBOLS["view.list"]!,
              label: panel.label,
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
      tool: { id, symbol: HEADER_SYMBOLS[icon]!, label, enabled: !!run, toggled: pressed === true },
      run,
      menuRuns: undefined,
    })),
  ]
    .slice(0, 16)
    .map(({ tool, run, menuRuns }) => ({ tool: { ...tool, label: boundedLabel(tool.label) }, run, menuRuns }));
}

/// Native and DOM invocations both resolve through the current binding callbacks.
export function dispatchNativeRowTool(value: unknown, bindings: readonly RowToolBinding[]): void {
  if (!value || typeof value !== "object") return;
  const event = value as { id?: unknown; menuItemId?: unknown };
  if (typeof event.id !== "string") return;
  const binding = bindings.find(({ tool }) => tool.id === event.id);
  if (!binding?.tool.enabled) return;
  if (event.menuItemId !== undefined) {
    if (typeof event.menuItemId !== "string") return;
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
  return () => {
    listeners.delete(listener);
  };
}
