// A liquid glass surface (glass.css, lens.ts): a `<div>` with `.ui-glass`. Any element may add the
// class itself; this is the React spelling, so a surface's own props and class pass straight through.
import type { HTMLAttributes } from "react";
import { cx } from "../cx";

export function Glass({ className, ...props }: HTMLAttributes<HTMLDivElement>) {
  return <div className={cx("ui-glass", className)} {...props} />;
}
