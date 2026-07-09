const POSTHOG_APP_HOST = (process.env.POSTHOG_APP_HOST ?? "https://us.posthog.com").replace(/\/$/, "");

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

  const response = await fetch(`${POSTHOG_APP_HOST}/api/environments/${encodeURIComponent(environmentId)}/persons/bulk_delete/`, {
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
  });
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
  if (deletionErrors.length > 0) {
    throw new Error(`PostHog account deletion failed: ${deletionErrors.length} deletion error(s)`);
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
