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

/** The handshake capability of a sidecar that hides white space (protocol.rs). */
export const HIDE_WHITESPACE_CAPABILITY = "session.ignoreWhitespace";

/**
 * Whether Hide white space can apply to `source`: the host's sidecar honors it
 * (`payload.sessionCapabilities`) and the source is git-backed. A patch source is
 * fixed text, so the sidecar cannot diff it again.
 */
export function hideWhitespaceAvailable(payload: any, source: DiffSource | null | undefined): boolean {
  const capabilities = payload?.sessionCapabilities;
  return (
    Array.isArray(capabilities) &&
    capabilities.includes(HIDE_WHITESPACE_CAPABILITY) &&
    validDiffSource(source) &&
    source.kind !== "patch"
  );
}

/**
 * The `sessionOpen` params for the shown source. With `hideWhitespace` on, where
 * it can apply, they ask for `ignoreWhitespace`: the diff then leaves out white
 * space changes, so its hunks are not the file's real hunks. A write of one hunk
 * (stage, unstage, revert) must not run on such a session; whole-file writes can.
 */
export function diffSessionRequest(
  payload: any,
  transport: DiffTransport | null,
  overrideSource?: DiffSource | null,
  hideWhitespace = false,
): {
  source: DiffSource;
  capabilityToken: string;
  ignoreWhitespace?: boolean;
} | null {
  if (!transport || typeof payload?.capabilityToken !== "string") {
    return null;
  }
  const source = overrideSource ?? payload.sessionSource;
  if (!validDiffSource(source)) {
    return null;
  }
  return {
    source,
    capabilityToken: payload.capabilityToken,
    ...(hideWhitespace && hideWhitespaceAvailable(payload, source) ? { ignoreWhitespace: true } : {}),
  };
}

/** The handshake capability of a sidecar that answers `fileContents` (protocol.rs). */
export const FILE_CONTENTS_CAPABILITY = "session.fileContents";

/**
 * Whether the host can read a file's two sides for `source` (`fileContents`, for Load full files
 * and Rich preview): its sidecar answers them (`payload.sessionCapabilities`) and the source is
 * git-backed. A patch source (a chat's turn) has no repository sides.
 */
export function fileContentsAvailable(payload: any, source: DiffSource | null | undefined): boolean {
  const capabilities = payload?.sessionCapabilities;
  return (
    Array.isArray(capabilities) &&
    capabilities.includes(FILE_CONTENTS_CAPABILITY) &&
    validDiffSource(source) &&
    source.kind !== "patch"
  );
}

/** One side of a file: text, or base64 for a binary file (an image). */
export type FileSide = { contents: string; encoding: "text" | "base64" };
/**
 * A file's two sides as the session's patch compares them. A side is missing when the file does
 * not exist on it (an added file has no old side); `tooLarge` sends neither.
 */
export type FileContents = { old?: FileSide; new?: FileSide; tooLarge?: boolean };

/**
 * Asks the host for a file's two sides in the shown session. Only a path the session's patch
 * names is answered (a binary file's `GIT binary patch` header counts); `previousPath` is a
 * rename's old path. `encoding: "base64"` for a binary file.
 */
export async function loadFileContents(
  transport: DiffTransport,
  session: ActiveDiffSession,
  file: { path: string; previousPath?: string; encoding?: "text" | "base64" },
): Promise<FileContents> {
  const result = await transport.request({
    method: "fileContents",
    params: {
      capabilityToken: session.capabilityToken,
      sessionId: session.sessionId,
      path: file.path,
      ...(file.previousPath ? { previousPath: file.previousPath } : {}),
      ...(file.encoding ? { encoding: file.encoding } : {}),
    },
  });
  if (result.type !== "fileContents") throw new Error("The host did not answer fileContents");
  return result.value;
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
