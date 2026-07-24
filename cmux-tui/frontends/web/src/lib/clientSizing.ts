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

function includeMinimum(
  minimum: PaneClientSummary["minimum"] | null,
  size: { cols: number; rows: number },
): PaneClientSummary["minimum"] {
  if (minimum === null) return { cols: size.cols, rows: size.rows };
  return {
    cols: Math.min(minimum.cols, size.cols),
    rows: Math.min(minimum.rows, size.rows),
  };
}

export function paneClientSummary(clients: ClientInfo[], surface: Id | null): PaneClientSummary | null {
  if (surface === null) return null;
  const visible: ClientInfo[] = [];
  let hasSelf = false;
  let hasPeer = false;
  let allMinimum: PaneClientSummary["minimum"] | null = null;
  let participatingMinimum: PaneClientSummary["minimum"] | null = null;
  let hasParticipatingAttachment = false;
  for (const client of clients) {
    const entry = client.sizes.find((candidate) => candidate.surface === surface);
    if (entry === undefined) continue;
    const participating = entry.size_participating !== false;
    hasParticipatingAttachment ||= participating;
    if (entry.cols === null || entry.rows === null) continue;
    const size = { cols: entry.cols, rows: entry.rows };
    visible.push(client);
    hasSelf ||= client.self;
    hasPeer ||= !client.self;
    allMinimum = includeMinimum(allMinimum, size);
    if (participating) {
      participatingMinimum = includeMinimum(participatingMinimum, size);
    }
  }
  if (!hasSelf || !hasPeer) return null;
  const minimum = hasParticipatingAttachment ? participatingMinimum : allMinimum;
  if (minimum === null) return null;
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
