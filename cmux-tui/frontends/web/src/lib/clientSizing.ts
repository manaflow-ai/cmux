import type { ClientInfo, Id } from "cmux/browser";
import type { ContextMenuItem } from "../components/ContextMenu";
import { t } from "../i18n";

export interface ClientSizingActions {
  setParticipation(surface: Id, client: Id, enabled: boolean): void;
  useOnly(surface: Id, client: Id): void;
  useAll(surface: Id): void;
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
  return {
    cols: size.cols,
    rows: size.rows,
    sizeParticipating: size.size_participating !== false,
  };
}

export function paneClientSummary(clients: ClientInfo[], surface: Id | null): PaneClientSummary | null {
  if (surface === null) return null;
  const visible = clients.filter((client) => surfaceSize(client, surface) !== null);
  if (!visible.some((client) => client.self) || !visible.some((client) => !client.self)) return null;
  const useExcluded = !visible.some(
    (client) => surfaceSize(client, surface)?.sizeParticipating,
  );
  const participants = visible.filter(
    (client) => useExcluded || surfaceSize(client, surface)?.sizeParticipating,
  );
  const sizes = participants.map((client) => {
    const size = surfaceSize(client, surface)!;
    return { cols: size.cols, rows: size.rows };
  });
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
    items.push({
      label: t("useOnlyThisClient"),
      onSelect: () => actions.useOnly(summary.surface, self.client),
    });
  }
  items.push({
    label: t("useAllClientSizes"),
    onSelect: () => actions.useAll(summary.surface),
  });
  items.push({ label: "", separator: true });
  for (const client of summary.clients) {
    const size = surfaceSize(client, summary.surface);
    const name = client.name || client.kind || t("unnamed");
    const label = size ? `${name} · ${size.cols}×${size.rows}` : name;
    const children: ContextMenuItem[] = [
      {
        label: t("useOnlyThisClient"),
        onSelect: () => actions.useOnly(summary.surface, client.client),
      },
      {
        label: size?.sizeParticipating ? t("excludeFromSizing") : t("useForSizing"),
        onSelect: () => actions.setParticipation(
          summary.surface,
          client.client,
          !size?.sizeParticipating,
        ),
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
