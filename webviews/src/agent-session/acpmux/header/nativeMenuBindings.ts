import type { ContextMenuItem } from "../../../ui/ContextMenu";
import type { ChatMenuItem } from "./ChatHeaderTools";
import type { NativeRowMenuItem } from "./nativeRowTools";

export interface NativeMenuBinding {
  items: NativeRowMenuItem[];
  invoke(id: string): void;
}

const encoder = new TextEncoder();
const characters = new Intl.Segmenter(undefined, { granularity: "grapheme" });

/** Native fields are at most 64 graphemes and 256 UTF-8 bytes, including combining marks. */
export function nativeMenuText(text: string): string {
  let result = "";
  let count = 0;
  for (const { segment } of characters.segment(text)) {
    if (++count > 64 || encoder.encode(result + segment).length > 256) break;
    result += segment;
  }
  return result || (text ? "…" : "");
}

/** Publish a complete menu or retain its DOM fallback; never silently lose overflowed rows. */
export function nativeChatMenu(rows: readonly ChatMenuItem[]): NativeMenuBinding | undefined {
  const callbacks = new Map<string, () => void>();
  const items: NativeRowMenuItem[] = [];
  let separatorBefore = false;
  let count = 0;
  const validId = (id: string) => !!id && nativeMenuText(id) === id;
  for (const row of rows) {
    if (row === "separator") {
      separatorBefore = items.length > 0;
      continue;
    }
    if (items.length >= 32 || ++count > 256 || !validId(row.key)) return;
    const id = row.key;
    const item: NativeRowMenuItem = {
      id,
      label: nativeMenuText(row.label),
      enabled: row.disabled !== true,
      ...(separatorBefore ? { separatorBefore: true } : {}),
    };
    separatorBefore = false;
    if (row.children) {
      if (row.children.length > 32 || (count += row.children.length) > 256) return;
      if (row.children.some((child) => !validId(`${id}/${child.key}`))) return;
      item.children = row.children.map((child) => {
        const childId = `${id}/${child.key}`;
        if (!row.disabled) callbacks.set(childId, child.onSelect);
        return { id: childId, label: nativeMenuText(child.label), enabled: !row.disabled };
      });
    } else if (!row.disabled && row.onSelect) {
      callbacks.set(id, () => row.onSelect?.());
    }
    items.push(item);
  }
  return { items, invoke: (id) => callbacks.get(id)?.() };
}

/** Both native and DOM customization use the same onSelect callbacks and enabled state. */
export function nativeCustomizeMenu(rows: readonly ContextMenuItem[]): NativeMenuBinding {
  const callbacks = new Map<string, () => void>();
  const items = rows.slice(0, 32).map((row): NativeRowMenuItem => {
    const id = `context:${row.id}`;
    if (!row.disabled) callbacks.set(id, row.onSelect);
    return {
      id,
      label: nativeMenuText(typeof row.label === "string" ? row.label : (row.ariaLabel ?? "")),
      enabled: !row.disabled,
      ...(row.checked !== undefined ? { checked: row.checked } : {}),
      ...(row.destructive ? { role: "destructive" } : {}),
      ...(row.separatorBefore ? { separatorBefore: true } : {}),
    };
  });
  return { items, invoke: (id) => callbacks.get(id)?.() };
}
