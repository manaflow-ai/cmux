// Settings' user-growing cards at any length: `count` live shares (Shared Links) or keys (Keys), for
// the windowed cards' count test and bench. Share `n` is the n-th newest, key `n` the n-th newest.
import type { KeysState, SharesState } from "../../src/pages/settings/ops";

const MINUTE = 60_000;

export function manyShares(count: number, now: number): SharesState {
  const titles: Record<string, string> = {};
  const shares = Array.from({ length: count }, (_, index) => {
    titles[String(index)] = `Shared chat ${index}`;
    return {
      share_id: `sh_${String(index).padStart(6, "0")}`,
      state: "active",
      session: `s-${index}`,
      surface: index,
      created_at: now - (index + 1) * MINUTE,
      expires_at: now + 24 * 60 * MINUTE,
      uses_left: 0,
      guests:
        index % 3 === 0 ? [{ guest_id: `g${index}`, name: `Guest ${index}`, joined_at: now, state: "active" }] : [],
      invitees: [],
    };
  });
  return { available: true, titles, shares };
}

export function manyKeys(count: number, now: number): KeysState {
  const at = (ms: number) => new Date(ms).toISOString().replace(/\.\d{3}Z$/, "Z");
  return {
    available: true,
    requests: [],
    keys: Array.from({ length: count }, (_, index) => ({
      id: `key_${String(index).padStart(6, "0")}`,
      label: `KEY_${index}`,
      name: `KEY_${index}`,
      provider: "local",
      kind: "secret",
      source: "stdin",
      purpose: index % 2 ? `What key ${index} is for` : null,
      hosts: [`api${index % 7}.example.com`],
      stores: [],
      uses: [],
      by: "user=leo",
      asked_by: null,
      created_at: at(now - (index + 1) * MINUTE),
      expires_at: at(now + 30 * 24 * 60 * MINUTE),
      state: "live",
    })),
  };
}
