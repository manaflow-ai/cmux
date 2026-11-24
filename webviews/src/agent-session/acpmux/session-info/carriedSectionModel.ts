// Session Info's Carried memory (CarriedSection.tsx): the instructions and memory files that follow the
// person to this machine (`_acpmux/agent_home`), and the notes other machines propose to add to them,
// each waiting for the person to accept or drop it (`_acpmux/agent_home_resolve`). Read when the
// section is drawn and open, as Environment's Changes row reads the folder's diff (changeCounts.ts),
// and again after each resolve; a read that comes back after the chat changed is dropped.
import { useCallback, useEffect, useState } from "react";

export type CarriedKind = "instructions" | "memory";
export type CarriedChange = "add" | "change" | "remove";

export type CarriedFile = { path: string; sha256: string; bytes: number; kind: CarriedKind };
export type CarriedEntry = {
  path: string;
  kind: CarriedKind;
  change: CarriedChange;
  /** Unified diff, capped by acpmux; null when it sent none (a removal, a binary file). */
  diff: string | null;
  bytes: number | null;
};
export type CarriedProposal = {
  id: string;
  device: string;
  baseRevision: number | null;
  /** When it was proposed, in ms; null when acpmux does not know. */
  at: number | null;
  entries: CarriedEntry[];
};
export type AgentHome = {
  /** False: no head on this machine (the setting is off, or the service is not reachable). */
  configured: boolean;
  generation: number;
  revision: number | null;
  carried: CarriedFile[];
  proposals: CarriedProposal[];
};
export type CarriedResolve = { accept: string[]; drop: string[] };
export type CarriedResolution = {
  accepted: string[];
  dropped: string[];
  refused: { id: string; reason: string }[];
  revision: number | null;
};

/// Reads `_acpmux/agent_home` for the chat (direct.ts `agentHome`).
export type ReadCarried = () => Promise<unknown>;
/// Sends `_acpmux/agent_home_resolve` (direct.ts `resolveAgentHome`), on the click with no await before it.
export type ResolveCarried = (change: CarriedResolve) => Promise<unknown>;

export const NOT_CONFIGURED: AgentHome = {
  configured: false,
  generation: 0,
  revision: null,
  carried: [],
  proposals: [],
};

const record = (value: unknown): Record<string, unknown> | undefined =>
  value && typeof value === "object" && !Array.isArray(value) ? (value as Record<string, unknown>) : undefined;
const list = (value: unknown): unknown[] => (Array.isArray(value) ? value : []);
const text = (value: unknown): string | undefined => (typeof value === "string" ? value : undefined);
const finite = (value: unknown): number | null => (typeof value === "number" && Number.isFinite(value) ? value : null);
const kindOf = (value: unknown): CarriedKind => (value === "instructions" ? "instructions" : "memory");
const changeOf = (value: unknown): CarriedChange => (value === "add" || value === "remove" ? value : "change");
const strings = (value: unknown): string[] => list(value).filter((item): item is string => typeof item === "string");

/// An `_acpmux/agent_home` reply as the section draws it; anything else reads as not configured.
export function parseAgentHome(reply: unknown): AgentHome {
  const raw = record(reply);
  if (!raw || raw.configured !== true) return NOT_CONFIGURED;
  const carried = list(raw.carried).flatMap((item): CarriedFile[] => {
    const file = record(item);
    const path = text(file?.path);
    return file && path
      ? [{ path, sha256: text(file.sha256) ?? "", bytes: finite(file.bytes) ?? 0, kind: kindOf(file.kind) }]
      : [];
  });
  const proposals = list(raw.proposals).flatMap((item): CarriedProposal[] => {
    const proposal = record(item);
    const id = text(proposal?.id);
    if (!proposal || !id) return [];
    const entries = list(proposal.entries).flatMap((value): CarriedEntry[] => {
      const entry = record(value);
      const path = text(entry?.path);
      return entry && path
        ? [
            {
              path,
              kind: kindOf(entry.kind),
              change: changeOf(entry.change),
              diff: text(entry.diff) ?? null,
              bytes: finite(entry.bytes),
            },
          ]
        : [];
    });
    return [
      {
        id,
        device: text(proposal.device) ?? "",
        baseRevision: finite(proposal.baseRevision),
        at: finite(proposal.at),
        entries,
      },
    ];
  });
  return {
    configured: true,
    generation: finite(raw.generation) ?? 0,
    revision: finite(raw.revision),
    carried,
    proposals,
  };
}

/// An `_acpmux/agent_home_resolve` reply; a reply that is no object settles nothing.
export function parseResolution(reply: unknown): CarriedResolution {
  const raw = record(reply);
  return {
    accepted: strings(raw?.accepted),
    dropped: strings(raw?.dropped),
    refused: list(raw?.refused).flatMap((item) => {
      const refusal = record(item);
      const id = text(refusal?.id);
      return id ? [{ id, reason: text(refusal?.reason) ?? "" }] : [];
    }),
    revision: finite(raw?.revision),
  };
}

/// The home with the settled proposals gone, so a click shows at once and a slow re-read never
/// brings a settled proposal back.
export function withoutSettled(home: AgentHome, settled: CarriedResolution): AgentHome {
  const gone = new Set([...settled.accepted, ...settled.dropped]);
  if (gone.size === 0) return home;
  return { ...home, proposals: home.proposals.filter((proposal) => !gone.has(proposal.id)) };
}

/// The carried memory for `key` (the chat) while `live` (the section drawn and open); `reload` reads
/// it again (after a resolve). Undefined until the first read answers; `failed` when it threw.
export function useCarried(
  read: ReadCarried | undefined,
  live: boolean,
  key: string,
): { home?: AgentHome; failed: boolean; reload: () => void; settle: (resolution: CarriedResolution) => void } {
  const [state, setState] = useState<{ key: string; home?: AgentHome; failed: boolean }>({ key: "", failed: false });
  const [reads, setReads] = useState(0);
  useEffect(() => {
    if (!read || !live) return;
    let current = true;
    Promise.resolve()
      .then(read)
      .then(
        (reply) => current && setState({ key, home: parseAgentHome(reply), failed: false }),
        () => current && setState((last) => ({ key, home: last.key === key ? last.home : undefined, failed: true })),
      );
    return () => {
      current = false;
    };
  }, [read, live, key, reads]);
  const reload = useCallback(() => setReads((count) => count + 1), []);
  const settle = useCallback(
    (resolution: CarriedResolution) =>
      setState((last) => (last.home ? { ...last, home: withoutSettled(last.home, resolution) } : last)),
    [],
  );
  // Another chat's files never show while this chat's read is in flight.
  return state.key === key
    ? { home: state.home, failed: state.failed, reload, settle }
    : { failed: false, reload, settle };
}

/// What the mock and the gallery answer: two files carried, and one proposal from another machine.
export function sampleAgentHome(now: number, proposals = 1): AgentHome {
  const all: CarriedProposal[] = [
    {
      id: "p-laptop-1",
      device: "MacBook Air",
      baseRevision: 13,
      at: now - 25 * 60_000,
      entries: [
        {
          path: "CLAUDE.md",
          kind: "instructions",
          change: "change",
          diff: "@@ -3,2 +3,3 @@\n # Rules\n-Run tests with npm.\n+Run tests with bun.\n+Never edit the generated files.\n",
          bytes: 1840,
        },
        {
          path: "memory/deploys.md",
          kind: "memory",
          change: "add",
          diff: "@@ -0,0 +1,2 @@\n+# Deploys\n+Staging deploys from the release branch only.\n",
          bytes: 64,
        },
      ],
    },
    {
      id: "p-cloud-2",
      device: "Cloud",
      baseRevision: 13,
      at: now - 3 * 3_600_000,
      entries: [{ path: "memory/old-notes.md", kind: "memory", change: "remove", diff: null, bytes: null }],
    },
  ];
  return {
    configured: true,
    generation: 4,
    revision: 14,
    carried: [
      { path: "CLAUDE.md", sha256: "a3f1", bytes: 1812, kind: "instructions" },
      { path: "AGENTS.md", sha256: "9b02", bytes: 960, kind: "instructions" },
      { path: "memory/MEMORY.md", sha256: "41cc", bytes: 2304, kind: "memory" },
      { path: "memory/old-notes.md", sha256: "7d10", bytes: 512, kind: "memory" },
    ],
    proposals: all.slice(0, proposals),
  };
}
