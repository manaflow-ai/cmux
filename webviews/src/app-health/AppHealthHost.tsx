// The app health popover on its route (`cmux-page://cmux.server-cards/#/app-health`), hosted as the
// server Health popover is (ServerSurfaceHost.tsx): the host shows the page in a popover anchored to
// the indicator, the page reports its size (useCardSize), and Escape reaches the popover, which
// closes itself. The host pushes each snapshot on `cmux.app.health.snapshot`; Repair goes back as
// `cmux.app.health.repair_now {id}`, from the person's click only.
import { useEffect, useRef, useState } from "react";
import type { PageClient } from "../pages/shared/pageClient";
import type { Strings } from "../pages/shared/i18n";
import { useCardSize } from "../pages/server-cards/host";
import { AppHealthPopover } from "./AppHealth";
import { APP_HEALTH_ROUTE, HealthOps, type HealthSnapshot } from "./types";

/** Follows the host's snapshots; the newest one wins (the stream is ordered). */
export function useHealthSnapshot(client: PageClient | null): HealthSnapshot | null {
  const [snapshot, setSnapshot] = useState<HealthSnapshot | null>(null);
  useEffect(() => {
    if (!client) return;
    let stop: (() => void) | undefined;
    let stopped = false;
    void client
      .subscribe<HealthSnapshot>(HealthOps.snapshot, (next) => setSnapshot(next))
      .then((unsubscribe) => (stopped ? unsubscribe() : (stop = unsubscribe)))
      .catch(() => {});
    return () => {
      stopped = true;
      stop?.();
    };
  }, [client]);
  return snapshot;
}

export function AppHealthHost({ client, strings }: { client: PageClient | null; strings: Strings }) {
  const snapshot = useHealthSnapshot(client);
  const ref = useRef<HTMLDivElement | null>(null);
  useCardSize(client, APP_HEALTH_ROUTE, ref);
  const repair = (id: string) => void client?.call(HealthOps.repairNow, { id }).catch(() => {});
  return (
    <div ref={ref} className="ah-frame" data-route={APP_HEALTH_ROUTE}>
      <AppHealthPopover snapshot={snapshot} strings={strings} repair={repair} />
    </div>
  );
}
