import type { ReactNode } from "react";

/** A row whose control is an action button rather than a setting. */
export function ActionRow({ title, help, children }: { title: string; help: string; children: ReactNode }) {
  return (
    <div className="row" tabIndex={-1} data-action-row="">
      <div className="row-main">
        <div className="row-label">
          <div className="row-title">{title}</div>
          <div className="row-help">{help}</div>
        </div>
        <div className="row-control">{children}</div>
      </div>
    </div>
  );
}
