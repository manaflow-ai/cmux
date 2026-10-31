import { HEADER_SYMBOLS } from "./headerSymbols";
import type { HeaderQuickTool } from "./headerQuickTools";

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
export interface RowToolBinding {
  tool: NativeRowTool;
  run?: () => void;
}

const characters = new Intl.Segmenter(undefined, { granularity: "grapheme" });
const boundedLabel = (label: string) =>
  label.length <= 64
    ? label
    : Array.from(characters.segment(label))
        .slice(0, 64)
        .map((part) => part.segment)
        .join("");

/// Summary has no badge today. Needs You keeps its web trigger and rich anchored list in this step.
/// Only the existing icon buttons are described, in the same order as the DOM.
export function nativeRowToolBindings(quick: readonly HeaderQuickTool[], panel?: NativeRowPanel): RowToolBinding[] {
  return [
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
    ...quick.map(({ id, icon, label, pressed, run }) => ({
      tool: { id, symbol: HEADER_SYMBOLS[icon]!, label, enabled: !!run, toggled: pressed === true },
      run,
    })),
  ]
    .slice(0, 16)
    .map(({ tool, run }) => ({ tool: { ...tool, label: boundedLabel(tool.label) }, run }));
}

/// A single dispatch table: both sources own the same callbacks, and stale/unknown native ids do nothing.
export function dispatchNativeRowTool(value: unknown, bindings: readonly RowToolBinding[]): void {
  if (!value || typeof value !== "object") return;
  const event = value as { id?: unknown; menuItemId?: unknown };
  // No migrated button has a menu in this step. Never turn an unknown menu item into a button click.
  if (typeof event.id !== "string" || event.menuItemId !== undefined) return;
  const binding = bindings.find(({ tool }) => tool.id === event.id);
  if (binding?.tool.enabled) binding.run?.();
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
