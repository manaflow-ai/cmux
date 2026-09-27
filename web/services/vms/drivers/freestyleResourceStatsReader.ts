import { Cache, Clock, Effect } from "effect";
import type { Freestyle } from "freestyle";
import { guestResourceSampleCommand } from "../guestResourceReporter";
import { parseVmResourceUsage, VM_RESOURCE_USAGE_MIN_INTERVAL_MS } from "../resourceUsage";
import type { VMResourceStatsResult } from "./types";

const PROBE_TIMEOUT_MS = 5_000;

/** Provider deletion raced the read; workflows must reconcile the VM row. */
class FreestyleResourceStatsNotFoundError extends Error {
  readonly status = 404;
  constructor() {
    super("resource stats VM not found");
    this.name = "FreestyleResourceStatsNotFoundError";
  }
}

/** Owns bounded, coalesced read-only sampling for one provider client. */
export class FreestyleResourceStatsReader {
  private readonly cache: Cache.Cache<string, VMResourceStatsResult | null, FreestyleResourceStatsNotFoundError>;

  constructor(
    private readonly client: (timeoutMs?: number) => Freestyle,
    private readonly clock: Clock.Clock = Clock.make(),
  ) {
    this.cache = Effect.runSync(Cache.make({
      capacity: 128,
      timeToLive: VM_RESOURCE_USAGE_MIN_INTERVAL_MS,
      lookup: (vmId: string) => this.sample(vmId),
    }).pipe(Effect.withClock(clock)));
  }

  /** Reuses both successful samples and failures for the minimum reporting interval. */
  read(vmId: string): Promise<VMResourceStatsResult | null> {
    return Effect.runPromise(this.cache.get(vmId).pipe(Effect.withClock(this.clock)));
  }

  private sample(vmId: string): Effect.Effect<VMResourceStatsResult | null, FreestyleResourceStatsNotFoundError> {
    return Effect.tryPromise({ try: async (signal) => {
      // The raw SDK fetch avoids its background-request polling loop. exec-await
      // returns 409 if paused concurrently; never start, retry, or heal the guest.
      const response = await this.client(PROBE_TIMEOUT_MS).fetch(`/v5/vms/${encodeURIComponent(vmId)}/exec-await`, {
        method: "POST",
        headers: { "content-type": "application/json" },
        signal,
        body: JSON.stringify({ command: guestResourceSampleCommand(), timeoutMs: PROBE_TIMEOUT_MS, linuxUser: "nobody" }),
      });
      if (response.status === 404) {
        throw new FreestyleResourceStatsNotFoundError();
      }
      if (response.status !== 200) return null;
      const result: unknown = await response.json();
      if (!result || typeof result !== "object" || !("statusCode" in result)
        || result.statusCode !== 0 || !("stdout" in result) || typeof result.stdout !== "string") return null;
      const usage = parseVmResourceUsage(JSON.parse(result.stdout.trim()));
      return usage ? { ...usage, resourceSampledAt: this.clock.unsafeCurrentTimeMillis() } : null;
    }, catch: (error) => error }).pipe(
      Effect.timeout(PROBE_TIMEOUT_MS),
      Effect.catchAll((error) => error instanceof FreestyleResourceStatsNotFoundError
        ? Effect.fail(error) : Effect.succeed(null)),
    );
  }
}
