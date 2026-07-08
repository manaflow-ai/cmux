const POSTHOG_APP_HOST = (process.env.POSTHOG_APP_HOST ?? "https://us.posthog.com").replace(/\/$/, "");

export function assertPostHogDeletionConfigured(): void {
  if (!postHogProjectId() || !postHogPersonalApiKey()) {
    throw new Error("PostHog account deletion is not configured");
  }
}

export async function deletePostHogPersonData(userId: string): Promise<void> {
  const projectId = postHogProjectId();
  const personalApiKey = postHogPersonalApiKey();
  if (!projectId || !personalApiKey) {
    throw new Error("PostHog account deletion is not configured");
  }

  const response = await fetch(`${POSTHOG_APP_HOST}/api/projects/${encodeURIComponent(projectId)}/persons/bulk_delete/`, {
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

function postHogProjectId(): string | null {
  return trimmedEnv("POSTHOG_PROJECT_ID");
}

function postHogPersonalApiKey(): string | null {
  return trimmedEnv("POSTHOG_PERSONAL_API_KEY");
}

function trimmedEnv(name: string): string | null {
  const value = process.env[name]?.trim();
  return value ? value : null;
}
