import { useReducer, useRef, type MouseEvent } from "react";
import type { ClientInfo, Id } from "cmux/browser";
import { t } from "../i18n";
import { contextMenuReducer } from "../lib/contextMenu";
import { MenuPopover } from "./ContextMenu";

interface ClientsIndicatorProps {
  clients: ClientInfo[];
  onRefresh(): void;
  onDetach(client: Id): void;
}

function sizeLabel(client: ClientInfo): string {
  if (client.sizes.length === 0) return "—";
  return client.sizes.map((size) => (
    size.cols === null || size.rows === null ? "—" : `${size.cols}x${size.rows}`
  )).join(", ");
}

export function ClientsIndicator({ clients, onRefresh, onDetach }: ClientsIndicatorProps) {
  const [menu, dispatchMenu] = useReducer(contextMenuReducer, { open: false });
  // The popover's outside-pointerdown dismiss fires before the trigger's
  // click, so a click on the open trigger would close-then-reopen. Remember
  // it was open at pointerdown and swallow that click to make it a toggle.
  const suppressReopen = useRef(false);
  const label = t("clientsCount", { count: clients.length });
  const open = (event: MouseEvent<HTMLButtonElement>) => {
    if (suppressReopen.current) {
      suppressReopen.current = false;
      return;
    }
    const rect = event.currentTarget.getBoundingClientRect();
    dispatchMenu({ type: "open", point: { x: rect.right - 280, y: rect.bottom } });
    onRefresh();
  };

  return (
    <span className="clients-indicator">
      <button
        aria-expanded={menu.open}
        aria-haspopup="menu"
        className="clients-trigger"
        onClick={open}
        onPointerDown={() => {
          suppressReopen.current = menu.open;
        }}
        type="button"
      >
        {label}
      </button>
      {menu.open && (
        <MenuPopover
          ariaLabel={label}
          className="clients-popover"
          onClose={() => dispatchMenu({ type: "close" })}
          point={menu.point}
        >
          <div className="clients-list">
            {clients.map((client) => (
              <div className="client-row" key={client.client}>
                <div className="client-row-heading">
                  <strong>{client.name || t("unnamed")}</strong>
                  {client.self && <span className="client-self">{t("thisDevice")}</span>}
                </div>
                <div className="client-meta">{client.kind || "—"} · {client.transport}</div>
                <div className="client-sizes">{sizeLabel(client)}</div>
                {!client.self && (
                  <button
                    className="danger client-disconnect"
                    onClick={() => {
                      dispatchMenu({ type: "close" });
                      onDetach(client.client);
                    }}
                    role="menuitem"
                    type="button"
                  >
                    {t("disconnect")}
                  </button>
                )}
              </div>
            ))}
          </div>
        </MenuPopover>
      )}
    </span>
  );
}
