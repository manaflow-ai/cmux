import type { ReactNode } from "react";
import { ResetSpacer } from "./ResetButton";

/** A row whose control is an action button rather than a setting. `data` adds `data-*` attributes. */
export function ActionRow({
  title,
  help,
  children,
  data,
}: {
  title: string;
  help: string;
  children: ReactNode;
  data?: Record<`data-${string}`, string>;
}) {
  return (
    <div className="row" tabIndex={-1} data-action-row="" {...data}>
      <div className="row-main">
        <div className="row-label">
          <div className="row-title">{title}</div>
          {help && <div className="row-help">{help}</div>}
        </div>
        <div className="row-control action-row-control">
          {children}
          <ResetSpacer />
        </div>
      </div>
    </div>
  );
}
