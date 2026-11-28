import type { ReactNode } from "react";

export function GroupHeader({ title, help, children }: { title: string; help?: string; children?: ReactNode }) {
  return (
    <div className="group-header">
      <div className="group-heading">
        <h3 className="group-title">{title}</h3>
        {help && <p className="row-help">{help}</p>}
      </div>
      {children && <div className="group-actions">{children}</div>}
    </div>
  );
}
