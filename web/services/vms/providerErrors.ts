const providerSubjectPattern =
  "(?:vm|virtual machine|sandbox|sandboxes|instance|container|machine|environment|resource)";
const providerMissingPattern =
  "(?:not found|does not exist|already deleted|has been deleted|was deleted|no such)";

function hasProviderMissingMessage(message: string): boolean {
  const normalized = message.toLowerCase();
  if (!normalized) return false;

  const subjectThenMissing = new RegExp(
    `\\b${providerSubjectPattern}\\b.{0,80}\\b${providerMissingPattern}\\b`,
  );
  const missingThenSubject = new RegExp(
    `\\b${providerMissingPattern}\\b.{0,80}\\b${providerSubjectPattern}\\b`,
  );
  if (subjectThenMissing.test(normalized) || missingThenSubject.test(normalized)) {
    return true;
  }

  return (
    /(^|[^0-9])404([^0-9]|$)/.test(normalized) &&
    /\b(not found|vm|sandbox|instance|container|machine|resource)\b/.test(normalized)
  );
}

export function isProviderNotFoundError(err: unknown): boolean {
  if (!err || typeof err !== "object") return false;
  const candidate = err as {
    code?: string | number;
    name?: string;
    status?: number;
    statusCode?: number;
    response?: { status?: number; data?: unknown };
    message?: string;
    cause?: unknown;
  };
  const status =
    candidate.status ??
    candidate.statusCode ??
    candidate.response?.status ??
    undefined;
  if (status === 404) return true;

  const code = String(candidate.code ?? candidate.name ?? "").toLowerCase();
  if (code === "not_found" || code === "notfound" || code === "404") return true;

  if (hasProviderMissingMessage(candidate.message ?? "")) return true;

  const responseData = candidate.response?.data;
  if (
    (typeof responseData === "string" && hasProviderMissingMessage(responseData)) ||
    (responseData &&
      typeof responseData === "object" &&
      hasProviderMissingMessage(JSON.stringify(responseData)))
  ) {
    return true;
  }

  if (candidate.cause) return isProviderNotFoundError(candidate.cause);
  return false;
}
