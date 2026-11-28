// Owns the diff session model: which source the viewer shows, the session the host opened for
// it, and the request that opens or closes one.
import { type DiffTransport } from "../diff/transport";
import type { DiffSource, SessionOpened } from "../diff/generated/protocol";

/** A session the host opened for the viewer (branchChange answers `sessionOpened`). */
export type AdoptedDiffSession = { session: SessionOpened; capabilityToken: string };

/** Switches the viewer to `source`: opens a session for it, or adopts `opened` when the host
 * already opened one. */
export type SelectSessionSource = (source: DiffSource, opened?: AdoptedDiffSession) => void;

export type ActiveDiffSession = {
  capabilityToken: string;
  sessionId: string;
};

export const pendingSessionID = "00000000-0000-0000-0000-000000000000";

export function closeDiffSession(transport: DiffTransport, session: ActiveDiffSession): Promise<void> {
  return transport.request({ method: "sessionClose", params: session }).then(
    () => {},
    () => {},
  );
}

export function diffSessionRequest(
  payload: any,
  transport: DiffTransport | null,
  overrideSource?: DiffSource | null,
): {
  source: DiffSource;
  capabilityToken: string;
} | null {
  if (!transport || typeof payload?.capabilityToken !== "string") {
    return null;
  }
  const source = overrideSource ?? payload.sessionSource;
  if (!validDiffSource(source)) {
    return null;
  }
  return { source, capabilityToken: payload.capabilityToken };
}

export function validDiffSource(value: unknown): value is DiffSource {
  if (!value || typeof value !== "object" || typeof (value as { kind?: unknown }).kind !== "string") {
    return false;
  }
  const source = value as { kind: string; repoRoot?: unknown; path?: unknown; baseRef?: unknown };
  if (source.kind === "patch") {
    return typeof source.path === "string";
  }
  if (source.kind === "unstaged" || source.kind === "staged") {
    return typeof source.repoRoot === "string";
  }
  return (
    source.kind === "branch" &&
    typeof source.repoRoot === "string" &&
    (source.baseRef == null || typeof source.baseRef === "string")
  );
}

export function diffSourceRepoRoot(source: DiffSource | null): string | null {
  return source && "repoRoot" in source ? source.repoRoot : null;
}

export function sourceSelectionWithActiveRepo(source: DiffSource, active: DiffSource | null): DiffSource {
  if (source.kind === "patch") {
    return source;
  }
  const activeRepo = diffSourceRepoRoot(active);
  if (!activeRepo) {
    return source;
  }
  if (source.kind === "branch") {
    return source.repoRoot === activeRepo
      ? { ...source, repoRoot: activeRepo }
      : { kind: "branch", repoRoot: activeRepo };
  }
  return { ...source, repoRoot: activeRepo };
}

export function repoSelectionWithActiveSource(source: DiffSource, active: DiffSource | null): DiffSource {
  const repoRoot = diffSourceRepoRoot(source);
  if (!repoRoot || !active || active.kind === "patch") {
    return source;
  }
  if (active.kind === "branch") {
    return active.repoRoot === repoRoot ? { ...active, repoRoot } : { kind: "branch", repoRoot };
  }
  return { ...active, repoRoot };
}

export function isStatusOnlyPayload(
  payload: any,
  transport: DiffTransport | null = null,
  sessionSource: DiffSource | null = null,
): boolean {
  if (payload?.pendingReplacement === true) {
    return diffSessionRequest(payload, transport, sessionSource) == null;
  }
  return typeof payload?.statusMessage === "string" && payload.statusMessage.length > 0;
}
