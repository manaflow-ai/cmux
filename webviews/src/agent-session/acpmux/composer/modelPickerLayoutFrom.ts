import type { ModelPickerProps } from "../modelPickerLayout";

/** An absent or newer layout leaves the ordinary model chip in place. */
export function modelPickerLayoutFrom(reply: unknown): ModelPickerProps["reasoningMenu"] {
  const picker = (reply as { modelPicker?: { modelMenu?: unknown; reasoningMenu?: unknown } } | null)?.modelPicker;
  if (picker?.modelMenu !== "search") return undefined;
  const placement = picker.reasoningMenu;
  return placement === "column" || placement === "separate" ? placement : undefined;
}
