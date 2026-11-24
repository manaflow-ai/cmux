import type { WidgetSize } from "../../../apps/scene/widgetsClient";
import { useNt } from "./strings";

export function useSizeName(): (size: WidgetSize) => string {
  const nt = useNt();
  return (size) =>
    size === "small"
      ? nt("widgets.size.small")
      : size === "medium"
        ? nt("widgets.size.medium")
        : nt("widgets.size.large");
}
