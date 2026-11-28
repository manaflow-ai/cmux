// What the sign-in page says when the auth service refuses a step. Kept free
// of React and the SDK so it is unit tested.

/** cmux.com's auth project; every other project is a development backend. */
export const PRODUCTION_STACK_PROJECT_ID = "9790718f-14cd-4f7e-824d-eaf527a82b82";

export type SignInErrorMessages = {
  errorGeneric: string;
  /** "This build's sign-in address isn't allowed on {backend}." */
  errorRedirectNotAllowed?: string;
  /** The development backend's name in that sentence. */
  backendDevelopment?: string;
};

/**
 * The auth service refused the page's own address (REDIRECT_URL_NOT_WHITELISTED):
 * its project does not trust this origin. Returns the refused origin (from the
 * error's `details.redirect_url`, else `fallbackOrigin`), or null for any other error.
 */
export function refusedRedirectOrigin(error: unknown, fallbackOrigin: string | null): string | null | undefined {
  if (!error || typeof error !== "object") return undefined;
  const known = error as { errorCode?: unknown; details?: unknown };
  if (known.errorCode !== "REDIRECT_URL_NOT_WHITELISTED") return undefined;
  const details = known.details as { redirect_url?: unknown } | undefined;
  const url = typeof details?.redirect_url === "string" ? details.redirect_url : null;
  if (url) {
    try {
      return new URL(url).origin;
    } catch {
      // Fall through to the page's own origin.
    }
  }
  return fallbackOrigin;
}

/** The backend whose auth project refused it, by project id. */
export function backendName(projectId: string | undefined, messages: SignInErrorMessages): string {
  if (projectId === PRODUCTION_STACK_PROJECT_ID) return "cmux.com";
  return messages.backendDevelopment ?? "the development backend";
}

/**
 * The message for a failed sign-in step: a refused redirect says plainly that
 * this build's sign-in address isn't allowed on the backend, naming the refused
 * origin; every other failure keeps the generic text.
 */
export function signInFailureMessage(
  error: unknown,
  messages: SignInErrorMessages,
  context: { projectId: string | undefined; pageOrigin: string | null },
): string {
  const origin = refusedRedirectOrigin(error, context.pageOrigin);
  if (origin === undefined || !messages.errorRedirectNotAllowed) return messages.errorGeneric;
  const sentence = messages.errorRedirectNotAllowed.replace("{backend}", backendName(context.projectId, messages));
  return origin ? `${sentence} (${origin})` : sentence;
}
