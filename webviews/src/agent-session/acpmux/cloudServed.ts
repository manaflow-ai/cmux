// The desktop host advertises Cloud launch support separately from connection readiness.
import { createContext, useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { pageIsKey, watchPageKey } from "./pageKey";

export type CloudConnectionReason = "none" | "signedOut" | "off" | "cloudOff";

const reasonLabels = {
  none: "composer.envNotConnected",
  signedOut: "turn.signInAgain",
  off: "picker.cloud.connectionOff",
  cloudOff: "picker.cloud.connectionOff",
} as const;

export type CloudServed = {
  runnableFamilies: readonly string[];
  servedHarnesses?: readonly string[];
  pendingHarnesses?: readonly string[];
  unavailableEndpointHarnesses?: readonly string[];
  families: Readonly<Partial<Record<string, boolean>>>;
  reasons?: Readonly<Partial<Record<string, CloudConnectionReason>>>;
};

/// Match the launch id using the host's CloudSetup.family(of:) rules.
export function cloudPickerFamily(served: CloudServed | undefined, harness: string): string | undefined {
  if (served?.servedHarnesses?.includes(harness) || served?.pendingHarnesses?.includes(harness)) return harness;
  if (served?.unavailableEndpointHarnesses?.includes(harness)) return undefined;
  const id = harness.toLowerCase();
  return served?.runnableFamilies.find(
    (family) => id === family || id.startsWith(family + "-") || id.startsWith(family + ":"),
  );
}

export function cloudPickerState(served: CloudServed | undefined, harness: string) {
  if (!served) return undefined;
  if (served.servedHarnesses?.includes(harness)) return "ready";
  if (served.pendingHarnesses?.includes(harness)) return "pending";
  const family = cloudPickerFamily(served, harness);
  if (!family) return "unsupported";
  const ready = served.families[family];
  return ready === undefined ? undefined : ready ? "ready" : "disconnected";
}

export function cloudPickerReason(served: CloudServed | undefined, harness: string) {
  const family = cloudPickerFamily(served, harness);
  return reasonLabels[(family && served?.reasons?.[family]) || "none"];
}

/// No readiness answer (including a host that predates runnableFamilies) leaves the local picker.
export function readCloudServed(reply: unknown): CloudServed | undefined {
  if (!reply || typeof reply !== "object") return undefined;
  const { families, runnableFamilies, reasons, servedHarnesses, pendingHarnesses, unavailableEndpointHarnesses } =
    reply as {
      families?: unknown;
      runnableFamilies?: unknown;
      servedHarnesses?: unknown;
      pendingHarnesses?: unknown;
      unavailableEndpointHarnesses?: unknown;
      reasons?: unknown;
    };
  if (!families || typeof families !== "object" || !Array.isArray(runnableFamilies)) return undefined;
  const runnable = runnableFamilies.filter((family): family is string => typeof family === "string");
  const decided = runnable.flatMap((family) => {
    const value = Object.getOwnPropertyDescriptor(families, family)?.value;
    return typeof value === "boolean" ? [[family, value] as const] : [];
  });
  const exact = Array.isArray(servedHarnesses)
    ? servedHarnesses.filter((id): id is string => typeof id === "string" && id.length > 0)
    : [];
  const unavailable = Array.isArray(unavailableEndpointHarnesses)
    ? unavailableEndpointHarnesses.filter((id): id is string => typeof id === "string" && id.length > 0)
    : [];
  const pending = Array.isArray(pendingHarnesses)
    ? pendingHarnesses.filter((id): id is string => typeof id === "string" && id.length > 0)
    : [];
  if (!decided.length && !exact.length && !pending.length && !unavailable.length) return undefined;
  const locked =
    reasons && typeof reasons === "object"
      ? decided.flatMap(([family, ready]) => {
          const value: unknown = Object.getOwnPropertyDescriptor(reasons, family)?.value;
          return !ready && (value === "none" || value === "signedOut" || value === "off" || value === "cloudOff")
            ? [[family, value] as const]
            : [];
        })
      : [];
  return {
    runnableFamilies: runnable,
    ...(exact.length ? { servedHarnesses: exact } : {}),
    ...(pending.length ? { pendingHarnesses: pending } : {}),
    ...(unavailable.length ? { unavailableEndpointHarnesses: unavailable } : {}),
    families: Object.fromEntries(decided),
    ...(locked.length ? { reasons: Object.fromEntries(locked) } : {}),
  };
}

/** Apply the returned family only if the composer is still on the same unsent pick. */
export function selectFamilyOnReturn(
  family: string,
  readPick: () => { harness: string | undefined; revision: readonly unknown[] } | undefined,
  select: () => void,
): () => void {
  const before = readPick();
  return () => {
    const current = readPick();
    if (!before || !current || before.harness !== current.harness) return;
    if (
      current.revision.length !== before.revision.length ||
      current.revision.some((value, index) => value !== before.revision[index])
    )
      return;
    if (cloudPickerFamily({ runnableFamilies: [family], families: {} }, current.harness ?? "") !== family) select();
  };
}

type Native = (method: string, params?: Record<string, unknown>) => Promise<unknown>;

type CloudReturn = {
  family: string;
  onReady(): void;
  unwatch(): void;
};

/// Read when Cloud is picked, when the picker opens, and once on return from Connect.
export function useCloudServed(
  call: Native,
  active: boolean,
  {
    watchKey = watchPageKey,
    isKey = pageIsKey,
    readMachine,
  }: {
    watchKey?: typeof watchPageKey;
    isKey?: typeof pageIsKey;
    readMachine?(): string | undefined;
  } = {},
) {
  const [served, setServed] = useState<CloudServed>();
  const reads = useRef(0);
  const pendingReturn = useRef<CloudReturn>(undefined);
  const returned = useRef<CloudReturn>(undefined);
  const callRef = useRef(call);
  useLayoutEffect(() => {
    callRef.current = call;
  }, [call]);
  const read = useCallback(() => {
    const id = ++reads.current;
    const machine = readMachine?.();
    void callRef.current("cloud.setup.state", machine ? { machine } : {}).then(
      (reply) => {
        if (id !== reads.current) return;
        const next = readCloudServed(reply);
        setServed(next);
        const wanted = returned.current;
        returned.current = undefined;
        const state = wanted && cloudPickerState(next, wanted.family);
        if (wanted && (state === "ready" || state === "pending")) wanted.onReady();
      },
      () => {
        if (id !== reads.current) return;
        returned.current = undefined;
        setServed(undefined);
      },
    );
  }, [readMachine]);
  const disarm = useCallback(() => {
    pendingReturn.current?.unwatch();
    pendingReturn.current = undefined;
    returned.current = undefined;
  }, []);
  useEffect(() => {
    if (!active) {
      setServed(undefined);
      return;
    }
    read();
    return () => {
      reads.current += 1;
      disarm();
    };
  }, [active, disarm, read]);
  const refresh = useCallback(() => {
    if (active) read();
  }, [active, read]);
  const openSettings = useCallback(
    (family: string, onReady: () => void) => {
      if (!active) return;
      disarm();
      // A new Connect replaces a return read already in flight.
      reads.current += 1;
      const wanted = {
        family,
        onReady,
        unwatch: watchKey(() => {
          if (!isKey() || pendingReturn.current !== wanted) return;
          disarm();
          returned.current = wanted;
          read();
        }),
      };
      pendingReturn.current = wanted;
      void callRef.current("cloud.connect", { family }).catch(() => {
        if (pendingReturn.current === wanted) disarm();
      });
    },
    [active, disarm, isKey, read, watchKey],
  );
  return useMemo(
    () => ({ ...(active && served ? { served } : {}), refresh, openSettings }),
    [active, served, refresh, openSettings],
  );
}

/// The setup state of a Cloud composer and the picker's Settings > Cloud > Cloud models destination.
export const CloudServedContext = createContext<
  { served?: CloudServed; refresh?(): void; openSettings?(family: string): void } | undefined
>(undefined);
