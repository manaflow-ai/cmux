// l10n-allow-file: bench link model, not shipped UI.
// A simulated link between the app and the daemon (Leo, 2026-11-22: "you guys need to be able to simulate the
// update/restart and the connection speed and what is actually displayed"). The restart-to-settled harness runs
// the chat page's socket through it (bench/first-load-after-restart.bench.ts `LINK=`), and the terminal's reattach
// measure in cmux-tui runs its socket through the same model with the same profiles (bench/link-profiles.json), so
// the chat's number and the terminal's come from one link.
//
// The model, per direction: a FIFO pipe. A message of n bytes handed to the link at t departs at
// d = max(t, pipeFreeAt) + n * 8 / bps (no wait when bps is 0, unlimited), sets pipeFreeAt = d, and arrives at
// d + rttMs / 2. Opening a connection costs one full round trip before the first byte can go.
import fs from "node:fs";
import path from "node:path";

export type LinkProfile = { rttMs: number; bps: number };

const PROFILES_FILE = path.join(import.meta.dir, "link-profiles.json");

/// Every named profile in link-profiles.json.
export function linkProfiles(): Record<string, LinkProfile> {
  const read = JSON.parse(fs.readFileSync(PROFILES_FILE, "utf8")) as { profiles: Record<string, LinkProfile> };
  return read.profiles;
}

/// The profile named `name`, or a thrown error naming the known ones.
export function linkProfile(name: string): LinkProfile {
  const profiles = linkProfiles();
  const found = profiles[name];
  if (!found) throw new Error(`LINK must be one of ${Object.keys(profiles).join(", ")}, not ${name}`);
  if (!(found.rttMs >= 0) || !(found.bps >= 0)) throw new Error(`link ${name}: rttMs and bps must be non-negative`);
  return found;
}

/// When a message of `bytes` handed over at `now` departs and arrives, given when the pipe is next free. Pure.
export function schedule(
  profile: LinkProfile,
  now: number,
  pipeFreeAt: number,
  bytes: number,
): { departAt: number; arriveAt: number } {
  const serialize = profile.bps > 0 ? (bytes * 8 * 1000) / profile.bps : 0;
  const departAt = Math.max(now, pipeFreeAt) + serialize;
  return { departAt, arriveAt: departAt + profile.rttMs / 2 };
}

/// One direction of one connection. `send` delivers each message, in order, when the model says it arrives.
/// Stop condition: `close` drops every pending delivery and its timer; a closed pipe delivers nothing more.
export class LinkPipe {
  private pipeFreeAt = 0;
  private lastArrival = 0;
  private readonly timers = new Set<ReturnType<typeof setTimeout>>();
  private closed = false;
  /// Bytes handed to this pipe so far.
  bytes = 0;

  constructor(
    private readonly profile: LinkProfile,
    private readonly now: () => number = () => performance.now(),
  ) {}

  send(message: string, deliver: (message: string) => void): void {
    if (this.closed) return;
    const size = Buffer.byteLength(message);
    this.bytes += size;
    const { departAt, arriveAt } = schedule(this.profile, this.now(), this.pipeFreeAt, size);
    this.pipeFreeAt = departAt;
    // Arrivals are in order by construction (departures are, latency is constant); held to it anyway.
    const at = Math.max(arriveAt, this.lastArrival);
    this.lastArrival = at;
    const wait = at - this.now();
    if (wait <= 0 && this.timers.size === 0) {
      deliver(message);
      return;
    }
    // fixed-wait: the link's own delivery time is what this models; each timer fires once or is cleared on close.
    const timer = setTimeout(
      () => {
        this.timers.delete(timer);
        if (!this.closed) deliver(message);
      },
      Math.max(0, wait),
    );
    this.timers.add(timer);
  }

  close(): void {
    this.closed = true;
    for (const timer of this.timers) clearTimeout(timer);
    this.timers.clear();
  }
}

/// The wait before a new connection's first byte may go: one round trip.
export function connectDelay(profile: LinkProfile): Promise<void> {
  if (profile.rttMs <= 0) return Promise.resolve();
  // fixed-wait: a connection's handshake round trip is the modeled cost; fires once.
  return new Promise((resolve) => setTimeout(resolve, profile.rttMs));
}
