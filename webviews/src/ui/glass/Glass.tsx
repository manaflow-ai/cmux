// A liquid glass surface (glass.css, lens.ts): a `<div>` with `.ui-glass`. Any element may add the
// class itself; this is the React spelling, so a surface's own props and class pass straight through.
import type { HTMLAttributes } from "react";
import { cx } from "../cx";

/** @deprecated Use `Glass` from kit/index.ts, which puts a region on the App's glass at a level; on an
 * element of your own, add the `ui-glass` class.
 * @status deprecated
 */
export function Glass({ className, ...props }: HTMLAttributes<HTMLDivElement>) {
  return <div className={cx("ui-glass", className)} {...props} />;
}
