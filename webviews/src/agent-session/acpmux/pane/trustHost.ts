import type { TrustSource } from "../folderTrust";
import { type HarnessHealth } from "../harnessHealthNoticeModel";
import { callNative } from "../callNative";

/// Folder trust lives with acpmux (or the mock daemon), else the native host.
/// Each harness's last health answer on this page (signed out, outdated, fine), drawn at once for
/// the next chat on that harness while it is read again (Leo 2026-10-19: the notice popped in late
/// and pushed the composer on each switch and reconnect).
export const knownHarnessHealth = new Map<string, HarnessHealth | undefined>();

/// Each local folder's GitHub repository (`#123` links in the transcript) from its last read.
export const knownGithubRepositories = new Map<string, string | undefined>();

export const trustSource: TrustSource = {
  get: (cwd) => callNative("acp.trust.get", { cwd }),
  set: (cwd, level) => callNative("acp.trust.set", { cwd, level }),
};
