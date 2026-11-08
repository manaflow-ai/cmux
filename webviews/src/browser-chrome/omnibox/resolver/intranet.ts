// Bare words the native intranet probe found to be hosts (IntranetHostMemory.swift). The probe
// (DNS lookups with a deadline) stays native; the host pushes each answer in, and the synchronous
// resolver reads the set on every keystroke and on Enter.
import { trimWhitespace } from "./url-text";

/**
 * `IntranetHostProbe.candidate`: the lowercased word when `text` is a bare single label that could
 * be a host (letters, digits and inner hyphens, not only digits, 2 to 63 characters).
 */
export function intranetCandidate(text: string): string | null {
  const word = trimWhitespace(text).toLowerCase();
  if (!/^[a-z0-9-]{2,63}$/.test(word)) return null;
  if (word.startsWith("-") || word.endsWith("-") || /^[0-9]+$/.test(word)) return null;
  return word;
}

export class IntranetHostMemory {
  private hosts = new Set<string>();

  constructor(hosts: Iterable<string> = []) {
    this.replaceAll(hosts);
  }

  /** Whether `label` (any case) resolved last time it was checked. */
  isIntranetHost(label: string): boolean {
    return this.hosts.has(label.toLowerCase());
  }

  /** Records the newest answer for `label`. */
  record(label: string, resolves: boolean): void {
    const key = label.toLowerCase();
    if (resolves) this.hosts.add(key);
    else this.hosts.delete(key);
  }

  /** A snapshot of every label that resolves, as the host pushes it. */
  replaceAll(hosts: Iterable<string>): void {
    this.hosts = new Set(Array.from(hosts, (host) => host.toLowerCase()));
  }
}
