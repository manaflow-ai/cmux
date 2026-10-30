import type { ReactNode } from "react";
import { ResetSpacer } from "./ResetButton";

/** A row whose control is an action button rather than a setting. */
export function ActionRow({ title, help, children }: { title: string; help: string; children: ReactNode }) {
  return (
    <div className="row" tabIndex={-1} data-action-row="">
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
