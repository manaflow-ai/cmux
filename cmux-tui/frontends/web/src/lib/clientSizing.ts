import type { ClientInfo, Id } from "cmux/browser";
import type { ContextMenuItem } from "../components/ContextMenu";
import { t } from "../i18n";

export interface ClientSizingActions {
  setParticipation(client: Id, enabled: boolean): void;
  useOnly(client: Id): void;
  useAll(): void;
  detach(client: Id): void;
}

export interface PaneClientSummary {
  label: string;
  clients: ClientInfo[];
  surface: Id;
  minimum: { cols: number; rows: number };
}

function surfaceSize(client: ClientInfo, surface: Id) {
  const size = client.sizes.find((candidate) => candidate.surface === surface);
  if (size?.cols === null || size?.rows === null || size === undefined) return null;
  return { cols: size.cols, rows: size.rows };
}

export function paneClientSummary(clients: ClientInfo[], surface: Id | null): PaneClientSummary | null {
  if (surface === null) return null;
  const visible = clients.filter((client) => surfaceSize(client, surface) !== null);
  if (!visible.some((client) => client.self) || !visible.some((client) => !client.self)) return null;
  const useExcluded = !clients.some(
    (client) => client.size_participating && client.attached.length > 0,
  );
  const participants = visible.filter((client) => useExcluded || client.size_participating);
  const sizes = participants.map((client) => surfaceSize(client, surface)!);
  if (sizes.length === 0) return null;
  const minimum = sizes.reduce((smallest, size) => ({
    cols: Math.min(smallest.cols, size.cols),
    rows: Math.min(smallest.rows, size.rows),
  }));
  return {
    clients: visible,
    surface,
    minimum,
    label: t("paneClients", { count: visible.length, cols: minimum.cols, rows: minimum.rows }),
  };
}

export function clientSizingMenuItems(
  summary: PaneClientSummary,
  actions: ClientSizingActions,
): ContextMenuItem[] {
  const self = summary.clients.find((client) => client.self);
  const items: ContextMenuItem[] = [];
  if (self) {
    items.push({ label: t("useOnlyThisClient"), onSelect: () => actions.useOnly(self.client) });
  }
  items.push({ label: t("useAllClientSizes"), onSelect: actions.useAll });
  items.push({ label: "", separator: true });
  for (const client of summary.clients) {
    const size = surfaceSize(client, summary.surface);
    const name = client.name || client.kind || t("unnamed");
    const label = size ? `${name} · ${size.cols}×${size.rows}` : name;
    const children: ContextMenuItem[] = [
      { label: t("useOnlyThisClient"), onSelect: () => actions.useOnly(client.client) },
      {
        label: client.size_participating ? t("excludeFromSizing") : t("useForSizing"),
        onSelect: () => actions.setParticipation(client.client, !client.size_participating),
      },
    ];
    if (!client.self) {
      children.push({
        label: t("disconnect"),
        danger: true,
        onSelect: () => actions.detach(client.client),
      });
    }
    items.push({ label, children });
  }
  return items;
}
