import * as Data from "effect/Data";

import { shareWorkerHTTPBaseUrl } from "./compatibility";

const SHARE_SESSION_REVOKE_TIMEOUT_MS = 2_000;

export class ShareSessionRelayError extends Data.TaggedError(
  "ShareSessionRelayError",
)<{
  readonly code:
    | "share_session_forbidden"
    | "share_session_not_found"
    | "share_worker_unavailable";
}> {}

export async function revokeShareSession(input: {
  readonly code: string;
  readonly token: string;
  readonly fetch?: typeof fetch;
  readonly timeoutMs?: number;
  readonly baseUrl?: string;
}): Promise<void> {
  const controller = new AbortController();
  const timeout = setTimeout(
    () => controller.abort(),
    input.timeoutMs ?? SHARE_SESSION_REVOKE_TIMEOUT_MS,
  );
  let response: Response;
  try {
    response = await (input.fetch ?? fetch)(
      `${shareWorkerHTTPBaseUrl(input.baseUrl)}/v2/share/sessions/${input.code}`,
      {
        method: "DELETE",
        headers: {
          authorization: `Bearer ${input.token}`,
        },
        cache: "no-store",
        redirect: "error",
        signal: controller.signal,
      },
    );
  } catch {
    throw new ShareSessionRelayError({
      code: "share_worker_unavailable",
    });
  } finally {
    clearTimeout(timeout);
  }
  if (response.status === 204) return;
  if (response.status === 404 || response.status === 410) {
    throw new ShareSessionRelayError({
      code: "share_session_not_found",
    });
  }
  if (response.status === 401 || response.status === 403) {
    throw new ShareSessionRelayError({
      code: "share_session_forbidden",
    });
  }
  throw new ShareSessionRelayError({
    code: "share_worker_unavailable",
  });
}
