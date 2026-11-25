// l10n-allow-file: the floating-roles sheet is a gallery page; its labels are fixture text and token names.
// The floating family on one sheet (gallery `ui.floating-roles`): a menu, a popover, a tooltip, a
// toast and a dialog, each drawn with its shipped classes, and under each the numbers the browser
// measured on it: the corner, the inset (the padding to what it holds), the height, and the corner
// of the control nested at that inset, next to the tier-2 role token (schemas/design-roles) it reads.
// The shells are static copies of the popups' markup (no portal or positioner), so all five sit
// side by side; their corner, inset and height come from the same rules the live popups take.
import { useLayoutEffect, useRef, useState, type ReactNode } from "react";
import { Notice } from "./Notice";
import { Button } from "./Button";

type Specimen = "menu" | "popover" | "tooltip" | "toast" | "dialog";
const SPECIMENS: Specimen[] = ["menu", "popover", "tooltip", "toast", "dialog"];
/** The element each specimen measures (its shell) and the control nested at its inset. */
const SHELL: Record<Specimen, { shell: string; inner: string }> = {
  menu: { shell: ".ui-popup.ui-menu", inner: ".ui-menu-item" },
  popover: { shell: ".ui-popup.ui-popover", inner: ".ui-menu-item" },
  tooltip: { shell: ".ui-tooltip", inner: ".ui-tooltip-hint" },
  toast: { shell: ".ui-notice", inner: "button" },
  dialog: { shell: ".ui-dialog", inner: "button" },
};

export interface Measure {
  specimen: Specimen;
  radius: number;
  inset: number;
  height: number;
  innerRadius: number | null;
  role: string;
}

const px = (value: string) => Math.round(Number.parseFloat(value || "0") * 100) / 100;

function measure(root: HTMLElement, specimen: Specimen): Measure | null {
  const box = root.querySelector<HTMLElement>(`[data-specimen="${specimen}"]`);
  const shell = box?.querySelector<HTMLElement>(SHELL[specimen].shell);
  if (!shell) return null;
  const style = getComputedStyle(shell);
  const inner = shell.querySelector<HTMLElement>(SHELL[specimen].inner);
  return {
    specimen,
    radius: px(style.borderTopLeftRadius),
    // The trailing padding: a toast's leading padding is its text inset, not its control inset.
    inset: px(style.paddingInlineEnd),
    height: px(String(shell.getBoundingClientRect().height)),
    innerRadius: inner ? px(getComputedStyle(inner).borderTopLeftRadius) : null,
    role: getComputedStyle(document.documentElement).getPropertyValue(`--role-${specimen}-radius`).trim(),
  };
}

function Card({ specimen, children }: { specimen: Specimen; children: ReactNode }) {
  return (
    <figure className="ui-floating-roles-card" data-specimen={specimen}>
      <figcaption>{specimen}</figcaption>
      <div className="ui-floating-roles-stage">{children}</div>
    </figure>
  );
}

const noop = () => undefined;

export function FloatingRoles() {
  const root = useRef<HTMLDivElement>(null);
  const [rows, setRows] = useState<Measure[]>([]);
  useLayoutEffect(() => {
    const node = root.current;
    if (!node) return;
    const read = () => setRows(SPECIMENS.map((s) => measure(node, s)).filter((m): m is Measure => m !== null));
    read();
    // Fonts and the host's variables can land after the first layout.
    const timer = window.setTimeout(read, 300);
    return () => window.clearTimeout(timer);
  }, []);
  return (
    <div ref={root} className="ui-floating-roles">
      <div className="ui-floating-roles-grid">
        <Card specimen="menu">
          <div className="ui-popup ui-glass ui-menu" role="menu" data-host-glass="menu">
            <div className="ui-menu-item" role="menuitem" data-highlighted="">
              Copy link
            </div>
            <div className="ui-menu-item" role="menuitem">
              Rename…
            </div>
            <div className="ui-menu-item" role="menuitem">
              Close tab
            </div>
          </div>
        </Card>
        <Card specimen="popover">
          <div className="ui-popup ui-glass ui-popover" data-host-glass="popover">
            <div className="ui-menu-item" data-highlighted="">
              claude-opus
            </div>
            <div className="ui-menu-item">codex</div>
          </div>
        </Card>
        <Card specimen="tooltip">
          <div className="ui-tooltip ui-glass" role="tooltip" data-host-glass="chip">
            <span className="ui-tooltip-hint">⌘W</span>
            <span className="ui-tooltip-text">Close tab</span>
          </div>
        </Card>
        <Card specimen="toast">
          <Notice
            kind="toast"
            placement="stack"
            message="Moved this chat to Cloud machine dev."
            actions={[{ id: "undo", label: "Undo", onSelect: noop }]}
          />
        </Card>
        <Card specimen="dialog">
          <div className="ui-dialog ui-glass" style={{ position: "static" }} data-host-glass="popover">
            <h2 className="ui-dialog-title">Delete this chat?</h2>
            <p className="ui-dialog-description">Its transcript stays in History.</p>
            <div className="ui-dialog-actions">
              <Button onClick={noop}>Cancel</Button>
              <Button variant="solid" onClick={noop}>
                Delete
              </Button>
            </div>
          </div>
        </Card>
      </div>
      <table className="ui-floating-roles-table" data-floating-roles-measured={rows.length}>
        <thead>
          <tr>
            <th>role</th>
            <th>corner</th>
            <th>inset</th>
            <th>height</th>
            <th>inner corner</th>
            <th>--role-*-radius</th>
          </tr>
        </thead>
        <tbody>
          {rows.map((row) => (
            <tr key={row.specimen} data-measure={JSON.stringify(row)}>
              <td>{row.specimen}</td>
              <td>{row.radius}</td>
              <td>{row.inset}</td>
              <td>{row.height}</td>
              <td>{row.innerRadius ?? "-"}</td>
              <td>{row.role || "(none)"}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
