// The app's timing for the in-memory mock (dev server and tests only): `?mock&latency=40` answers
// every call and starts every subscription after that many milliseconds, as the host's bridge
// does; `?mock&parked` holds every call until `window.__cmuxSettingsClaim()`, as a pooled page's
// calls wait for the host's claim (pageClient.ts). test/settings-open-frames.test.ts records a
// Settings open with both.
import type { SettingsClient } from "./ops";
import { holdPaintForClaim } from "../shared/paintGate";
import { PARKED_NAME } from "../shared/pageClient";

type Held = () => void;

export function withMockTiming(client: SettingsClient, search: URLSearchParams): SettingsClient {
  const latency = Math.max(0, Number(search.get("latency") ?? 0) || 0);
  let parked = search.has("parked");
  const held: Held[] = [];
  if (parked) {
    // As the host parks a pooled document, and as pageClient.ts claims it.
    (globalThis as Record<string, unknown>)[PARKED_NAME] = true;
    (globalThis as { __cmuxSettingsClaim?: () => void }).__cmuxSettingsClaim = () => {
      parked = false;
      for (const run of held.splice(0)) run();
      holdPaintForClaim();
    };
  }
  const wait = () =>
    new Promise<void>((resolve) => {
      const go = () => (latency ? setTimeout(resolve, latency) : resolve());
      if (parked) held.push(go);
      else go();
    });
  return {
    async call<R>(op: string, params: unknown, opts?: { signal?: AbortSignal }): Promise<R> {
      await wait();
      return client.call<R>(op, params, opts);
    },
    async subscribe<E>(stream: string, onEvent: (data: E, seq: number) => void) {
      await wait();
      return client.subscribe<E>(stream, (data, seq) => {
        if (latency) setTimeout(() => onEvent(data, seq), latency);
        else onEvent(data, seq);
      });
    },
  };
}
