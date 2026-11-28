export type MachineLink = { machine: string; link: string; words: string };

let current: MachineLink | null = null;
const listeners = new Set<() => void>();

export function setMachineLink(value: unknown): void {
  const next = readMachineLink(value);
  if (next?.machine === current?.machine && next?.link === current?.link && next?.words === current?.words) return;
  current = next;
  for (const listener of listeners) listener();
}

export function readMachineLink(value: unknown): MachineLink | null {
  if (!value || typeof value !== "object") return null;
  const raw = value as Record<string, unknown>;
  if (typeof raw.machine !== "string" || typeof raw.link !== "string" || typeof raw.words !== "string") return null;
  return { machine: raw.machine, link: raw.link, words: raw.words };
}

export function machineLink(): MachineLink | null {
  return current;
}
