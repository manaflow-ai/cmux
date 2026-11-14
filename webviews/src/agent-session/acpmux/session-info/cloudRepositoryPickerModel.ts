import { postNative } from "../native";

export type AttachedCloudRepo = { repo: string; folder?: string; head?: string };
export type PendingCloudRepo = {
  repo: string;
  state?: string;
  phase?: string;
  progress?: { received_bytes?: number; objects?: number; total_objects?: number };
  notes?: string[];
};

export function loadAttachedCloudRepos(
  _session: string,
): Promise<{ repos: AttachedCloudRepo[]; pending: PendingCloudRepo[] }> {
  return postNative<{ repos?: AttachedCloudRepo[]; pending?: PendingCloudRepo[] }>("cloud.repo.attached", {}).then(
    (reply) => ({
      repos: Array.isArray(reply?.repos)
        ? reply.repos.filter((repo): repo is AttachedCloudRepo => Boolean(repo) && typeof repo.repo === "string")
        : [],
      pending: Array.isArray(reply?.pending)
        ? reply.pending.filter((repo): repo is PendingCloudRepo => Boolean(repo) && typeof repo.repo === "string")
        : [],
    }),
  );
}
