const providerSubjectPattern =
  "(?:vm|virtual machine|sandbox|sandboxes|instance|container|machine|environment|resource)";
const providerIdentitySubjectPattern =
  "(?:identity|identities|credential|credentials)";
const providerMissingPattern =
  "(?:not found|does not exist|already deleted|has been deleted|was deleted|marked as deleted|no such)";

function hasProviderMissingMessage(
  message: string,
  subjectPattern: string = providerSubjectPattern,
): boolean {
  const normalized = message.toLowerCase();
  if (!normalized) return false;

  const subjectThenMissing = new RegExp(
    `\\b${subjectPattern}\\b.{0,80}\\b${providerMissingPattern}\\b`,
  );
  const missingThenSubject = new RegExp(
    `\\b${providerMissingPattern}\\b.{0,80}\\b${subjectPattern}\\b`,
  );
  if (subjectThenMissing.test(normalized) || missingThenSubject.test(normalized)) {
    return true;
  }

  return (
    /(^|[^0-9])404([^0-9]|$)/.test(normalized) &&
    new RegExp(`\\b(not found|${subjectPattern})\\b`).test(normalized)
  );
}

type ProviderFailure = {
  code?: string | number;
  name?: string;
  status?: number;
  statusCode?: number;
  response?: { status?: number; data?: unknown };
  message?: string;
  cause?: unknown;
};

function hasLegacyProviderNotFoundDetail(candidate: ProviderFailure): boolean {
  const code = String(candidate.code ?? candidate.name ?? "").toLowerCase();
  if (
    code === "not_found" ||
    code === "notfound" ||
    code === "404" ||
    code === "vmdeletederror" ||
    code === "vm_deleted"
  ) {
    return true;
  }

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

  return false;
}

function httpStatus(candidate: ProviderFailure): number | undefined {
  const candidates = [candidate.status, candidate.statusCode, candidate.response?.status];
  return candidates.find((status): status is number =>
    typeof status === "number" && status >= 400 && status <= 599,
  );
}

function providerStatus(candidate: ProviderFailure): number | undefined {
  return candidate.status ?? candidate.statusCode ?? candidate.response?.status;
}

function hasProviderIdentityMissingDetail(candidate: ProviderFailure): boolean {
  if (hasProviderMissingMessage(candidate.message ?? "", providerIdentitySubjectPattern)) {
    return true;
  }

  const responseData = candidate.response?.data;
  if (typeof responseData === "string") {
    return hasProviderMissingMessage(responseData, providerIdentitySubjectPattern);
  }
  if (responseData && typeof responseData === "object") {
    return hasProviderMissingMessage(JSON.stringify(responseData), providerIdentitySubjectPattern);
  }
  return false;
}

export function isProviderNotFoundError(err: unknown): boolean {
  const seen = new Set<unknown>();
  let legacyNotFound = false;
  let current = err;
  while (current && typeof current === "object" && !seen.has(current)) {
    seen.add(current);
    const candidate = current as ProviderFailure;
    const status = httpStatus(candidate);
    // The concrete HTTP failure wins over wrapper/code/message heuristics.
    // A 502 mentioning a missing VM must never mark the machine destroyed.
    if (status !== undefined) return status === 404;
    legacyNotFound ||= hasLegacyProviderNotFoundDetail(candidate);
    current = candidate.cause;
  }
  return legacyNotFound;
}

/**
 * A destructive delete is confirmed only by the provider's explicit
 * not-found contract. A bare 404 with an unknown code may be an endpoint or
 * gateway error and must retain the allocation for a later retry.
 */
export function isProviderDeletionConfirmed(err: unknown): boolean {
  const seen = new Set<unknown>();
  let current = err;
  while (current && typeof current === "object" && !seen.has(current)) {
    seen.add(current);
    const candidate = current as ProviderFailure;
    const status = httpStatus(candidate);
    const code = String(candidate.code ?? "").toUpperCase();
    if (status !== undefined) return status === 404 && code === "NOT_FOUND";
    current = candidate.cause;
  }
  return false;
}

export function isProviderIdentityNotFoundError(err: unknown): boolean {
  if (!err || typeof err !== "object") return false;
  const candidate = err as ProviderFailure;
  if (providerStatus(candidate) === 404) return true;

  const code = String(candidate.code ?? candidate.name ?? "").toLowerCase();
  if (["not_found", "notfound", "404"].includes(code)) return true;
  if (hasProviderIdentityMissingDetail(candidate)) return true;
  return candidate.cause ? isProviderIdentityNotFoundError(candidate.cause) : false;
}
