const POSTHOG_APP_HOST = (process.env.POSTHOG_APP_HOST ?? "https://us.posthog.com").replace(/\/$/, "");
const DEFAULT_POSTHOG_DELETION_TIMEOUT_MS = 5_000;

export function assertPostHogDeletionConfigured(): void {
  if (!postHogEnvironmentId() || !postHogPersonalApiKey()) {
    throw new Error("PostHog account deletion is not configured");
  }
}

export async function deletePostHogPersonData(
  userId: string,
  distinctIds: readonly string[] = [userId],
): Promise<void> {
  const environmentId = postHogEnvironmentId();
  const personalApiKey = postHogPersonalApiKey();
  if (!environmentId || !personalApiKey) {
    throw new Error("PostHog account deletion is not configured");
  }
  const deletionDistinctIds = normalizedDistinctIds([userId, ...distinctIds]);

  const controller = new AbortController();
  const timeout = setTimeout(() => {
    controller.abort(new Error("PostHog account deletion timed out"));
  }, postHogDeletionTimeoutMs());
  let response: Response;
  try {
    response = await fetch(`${POSTHOG_APP_HOST}/api/environments/${encodeURIComponent(environmentId)}/persons/bulk_delete/`, {
      method: "POST",
      headers: {
        "Authorization": `Bearer ${personalApiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        distinct_ids: deletionDistinctIds,
        delete_events: true,
        delete_recordings: true,
      }),
      signal: controller.signal,
    });
  } catch (error) {
    if (controller.signal.aborted) {
      throw new Error("PostHog account deletion timed out", { cause: error });
    }
    throw error;
  } finally {
    clearTimeout(timeout);
  }
  if (!response.ok) {
    throw new Error(`PostHog account deletion failed: ${response.status}`);
  }
  await assertBulkDeleteResponseSucceeded(response);
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

function normalizedDistinctIds(values: readonly string[]): string[] {
  return Array.from(new Set(values.map((value) => value.trim()).filter(Boolean)));
}

async function assertBulkDeleteResponseSucceeded(response: Response): Promise<void> {
  const responseText = await response.text();
  if (!responseText.trim()) return;

  let responseBody: unknown;
  try {
    responseBody = JSON.parse(responseText);
  } catch {
    throw new Error("PostHog account deletion failed: invalid response");
  }

  if (!isRecord(responseBody) || !("deletion_errors" in responseBody)) return;
  const deletionErrors = responseBody.deletion_errors;
  if (!Array.isArray(deletionErrors)) {
    throw new Error("PostHog account deletion failed: invalid deletion errors");
  }
  const blockingErrors = deletionErrors.filter((error) => !isAlreadyDeletedPostHogError(error));
  if (blockingErrors.length > 0) {
    throw new Error(`PostHog account deletion failed: ${blockingErrors.length} deletion error(s)`);
  }
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
