const POSTHOG_APP_HOST = (process.env.POSTHOG_APP_HOST ?? "https://us.posthog.com").replace(/\/$/, "");
const DEFAULT_POSTHOG_DELETION_TIMEOUT_MS = 5_000;

export type PostHogDeletionResult = "completed" | "pending";

export function assertPostHogDeletionConfigured(): void {
  if (!postHogEnvironmentId() || !postHogPersonalApiKey()) {
    throw new Error("PostHog account deletion is not configured");
  }
}

export async function deletePostHogPersonData(
  userId: string,
  distinctIds: readonly string[] = [userId],
): Promise<PostHogDeletionResult> {
  const environmentId = postHogEnvironmentId();
  const personalApiKey = postHogPersonalApiKey();
  if (!environmentId || !personalApiKey) {
    throw new Error("PostHog account deletion is not configured");
  }
  const deletionDistinctIds = normalizedDistinctIds([userId, ...distinctIds]);

  const response = await postHogRequest({
    path: `/api/environments/${encodeURIComponent(environmentId)}/persons/bulk_delete/`,
    method: "POST",
    personalApiKey,
    body: {
      distinct_ids: deletionDistinctIds,
      delete_events: true,
      delete_recordings: true,
    },
  });
  if (!response.ok) {
    throw new Error(`PostHog account deletion failed: ${response.status}`);
  }
  const result = await bulkDeleteResult(response);
  return result.queued ? "pending" : "completed";
}

export async function isPostHogPersonDataDeletionComplete(): Promise<boolean> {
  const environmentId = postHogEnvironmentId();
  const personalApiKey = postHogPersonalApiKey();
  if (!environmentId || !personalApiKey) {
    throw new Error("PostHog account deletion is not configured");
  }
  const response = await postHogRequest({
    path: `/api/environments/${encodeURIComponent(environmentId)}/persons/deletion_status/?status=pending&limit=1`,
    method: "GET",
    personalApiKey,
  });
  if (!response.ok) {
    throw new Error(`PostHog account deletion status failed: ${response.status}`);
  }
  return await deletionStatusIsComplete(response);
}

async function postHogRequest(input: {
  readonly path: string;
  readonly method: "GET" | "POST";
  readonly personalApiKey: string;
  readonly body?: unknown;
}): Promise<Response> {
  const controller = new AbortController();
  const timeout = setTimeout(() => {
    controller.abort(new Error("PostHog account deletion timed out"));
  }, postHogDeletionTimeoutMs());
  let response: Response;
  try {
    response = await fetch(`${POSTHOG_APP_HOST}${input.path}`, {
      method: input.method,
      headers: {
        "Authorization": `Bearer ${input.personalApiKey}`,
        "Content-Type": "application/json",
      },
      body: typeof input.body === "undefined" ? undefined : JSON.stringify(input.body),
      signal: controller.signal,
    });
  } catch (error) {
    if (controller.signal.aborted || isAbortError(error)) {
      throw new Error("PostHog account deletion timed out", { cause: error });
    }
    throw error;
  } finally {
    clearTimeout(timeout);
  }
  return response;
}

function postHogEnvironmentId(): string | null {
  return trimmedEnv("POSTHOG_ENVIRONMENT_ID") ?? trimmedEnv("POSTHOG_PROJECT_ID");
}

function postHogPersonalApiKey(): string | null {
  return trimmedEnv("POSTHOG_PERSONAL_API_KEY");
}

function trimmedEnv(name: string): string | null {
  const value = process.env[name]?.trim();
  return value ? value : null;
}

function postHogDeletionTimeoutMs(): number {
  const configured = Number(process.env.POSTHOG_DELETION_TIMEOUT_MS);
  return Number.isFinite(configured) && configured > 0
    ? configured
    : DEFAULT_POSTHOG_DELETION_TIMEOUT_MS;
}

function isAbortError(error: unknown): boolean {
  return error instanceof Error && error.name === "AbortError";
}

function normalizedDistinctIds(values: readonly string[]): string[] {
  return Array.from(new Set(values.map((value) => value.trim()).filter(Boolean)));
}

async function bulkDeleteResult(response: Response): Promise<{ readonly queued: boolean }> {
  const responseText = await response.text();
  if (!responseText.trim()) return { queued: response.status === 202 };

  let responseBody: unknown;
  try {
    responseBody = JSON.parse(responseText);
  } catch {
    throw new Error("PostHog account deletion failed: invalid response");
  }

  if (!isRecord(responseBody)) {
    throw new Error("PostHog account deletion failed: invalid response");
  }
  const queued =
    responseBody.events_queued_for_deletion === true ||
    responseBody.recordings_queued_for_deletion === true;
  if (!("deletion_errors" in responseBody)) return { queued };
  const deletionErrors = responseBody.deletion_errors;
  if (!Array.isArray(deletionErrors)) {
    throw new Error("PostHog account deletion failed: invalid deletion errors");
  }
  const blockingErrors = deletionErrors.filter((error) => !isAlreadyDeletedPostHogError(error));
  if (blockingErrors.length > 0) {
    throw new Error(`PostHog account deletion failed: ${blockingErrors.length} deletion error(s)`);
  }
  return { queued };
}

async function deletionStatusIsComplete(response: Response): Promise<boolean> {
  const responseText = await response.text();
  if (!responseText.trim()) return true;
  let responseBody: unknown;
  try {
    responseBody = JSON.parse(responseText);
  } catch {
    throw new Error("PostHog account deletion status failed: invalid response");
  }
  if (!isRecord(responseBody)) {
    throw new Error("PostHog account deletion status failed: invalid response");
  }
  if (typeof responseBody.count === "number" && responseBody.count > 0) return false;
  return !(Array.isArray(responseBody.results) && responseBody.results.length > 0);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isAlreadyDeletedPostHogError(value: unknown): boolean {
  const normalized = postHogDeletionErrorText(value).toLowerCase().replace(/[^a-z0-9]+/g, " ");
  return /\b(not found|does not exist|no such|already deleted|has been deleted|was deleted)\b/.test(normalized);
}

function postHogDeletionErrorText(value: unknown): string {
  if (typeof value === "string") return value;
  if (!isRecord(value)) return "";
  const textParts = [
    value.error,
    value.message,
    value.detail,
    value.code,
  ].filter((part): part is string => typeof part === "string");
  if (textParts.length > 0) return textParts.join(" ");
  try {
    return JSON.stringify(value);
  } catch {
    return "";
  }
}
