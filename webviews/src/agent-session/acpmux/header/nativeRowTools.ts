import { HEADER_SYMBOLS } from "./headerSymbols";
import type { HeaderQuickTool } from "./headerQuickTools";

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
  contextMenu?: NativeRowMenuItem[];
}
export interface NativeRowMenuItem {
  id: string;
  label: string;
  enabled: boolean;
  checked?: boolean;
  role?: "destructive";
  children?: NativeRowMenuItem[];
  separatorBefore?: boolean;
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
  runMenu?: (id: string) => void;
  /// A future publisher can reserve these rows before variable menus consume the aggregate budget.
  menuPriority?: "fixed" | "variable";
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

const menuCost = (item: NativeRowMenuItem): number =>
  1 + (item.children?.reduce((sum, child) => sum + menuCost(child), 0) ?? 0);

function boundedMenu(items: readonly NativeRowMenuItem[]): NativeRowMenuItem[] {
  return items.slice(0, NATIVE_MAX_MENU_ITEMS).map((item) => ({
    ...item,
    id: boundedNativeText(item.id, "item"),
    label: boundedNativeText(item.label),
    ...(item.children ? { children: boundedMenu(item.children) } : {}),
  }));
}

/// Bound every native menu in one payload. Fixed menus are reserved first; variable menus are
/// truncated at whole rows so the aggregate decoder budget remains valid for every publisher.
export function fitNativeRowMenus(bindings: readonly RowToolBinding[]): RowToolBinding[] {
  let remaining = NATIVE_MAX_TOTAL_MENU_ITEMS;
  const order = bindings
    .map((binding, index) => ({ binding, index }))
    .sort((a, b) => Number(b.binding.menuPriority === "fixed") - Number(a.binding.menuPriority === "fixed"));
  const result = bindings.slice();
  for (const { binding, index } of order) {
    const boundTool = { ...binding.tool };
    for (const key of ["menu", "contextMenu"] as const) {
      const source = boundTool[key];
      if (!source) continue;
      const kept: NativeRowMenuItem[] = [];
      for (const item of boundedMenu(source)) {
        const cost = menuCost(item);
        if (cost <= remaining && kept.length < NATIVE_MAX_MENU_ITEMS) {
          kept.push(item);
          remaining -= cost;
        }
      }
      boundTool[key] = kept;
    }
    boundTool.label = boundedNativeText(boundTool.label, "Tool");
    if (boundTool.badge !== undefined) boundTool.badge = boundedNativeText(boundTool.badge, "0");
    result[index] = { ...binding, tool: boundTool };
  }
  return result;
}

/// Summary has no badge today. Needs You keeps its web trigger and rich anchored list in this step.
/// Only the existing icon buttons are described, in the same order as the DOM.
export function nativeRowToolBindings(quick: readonly HeaderQuickTool[], panel?: NativeRowPanel): RowToolBinding[] {
  const bindings = [
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
  ].slice(0, NATIVE_MAX_TOOLS);
  return fitNativeRowMenus(bindings);
}

/// A single dispatch table: both sources own the same callbacks, and stale/unknown native ids do nothing.
export function dispatchNativeRowTool(value: unknown, bindings: readonly RowToolBinding[]): void {
  if (!value || typeof value !== "object") return;
  const event = value as { id?: unknown; menuItemId?: unknown };
  if (typeof event.id !== "string") return;
  const binding = bindings.find(({ tool }) => tool.id === event.id);
  if (!binding?.tool.enabled) return;
  if (typeof event.menuItemId === "string") {
    binding.runMenu?.(event.menuItemId);
  } else if (event.menuItemId === undefined) {
    binding.run?.();
  }
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
