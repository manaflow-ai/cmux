const POSTHOG_APP_HOST = (process.env.POSTHOG_APP_HOST ?? "https://us.posthog.com").replace(/\/$/, "");

export function assertPostHogDeletionConfigured(): void {
  if (!postHogEnvironmentId() || !postHogPersonalApiKey()) {
    throw new Error("PostHog account deletion is not configured");
  }
}

export async function deletePostHogPersonData(userId: string): Promise<void> {
  const environmentId = postHogEnvironmentId();
  const personalApiKey = postHogPersonalApiKey();
  if (!environmentId || !personalApiKey) {
    throw new Error("PostHog account deletion is not configured");
  }

  const response = await fetch(`${POSTHOG_APP_HOST}/api/environments/${encodeURIComponent(environmentId)}/persons/bulk_delete/`, {
    method: "POST",
    headers: {
      "Authorization": `Bearer ${personalApiKey}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      distinct_ids: [userId],
      delete_events: true,
      delete_recordings: true,
    }),
  });
  if (!response.ok) {
    throw new Error(`PostHog account deletion failed: ${response.status}`);
  }
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
