export const SENSITIVE_CONTEXT_KEY = /account.?id|authorization|body|content|cookie|credential|email|header|key|prompt|response|secret|session|team.?id|token/i;

export function addCoderouterBreadcrumb(
  category: string,
  message: string,
  data: Readonly<Record<string, string | number | boolean>> = {},
  level: "debug" | "info" | "warning" | "error" = "info",
): void {
  const safeData = Object.fromEntries(
    Object.entries(data).filter(([key]) => !SENSITIVE_CONTEXT_KEY.test(key)),
  );
  void import("@sentry/nextjs")
    .then((Sentry) => {
      Sentry.addBreadcrumb({
        category: `coderouter.${category}`,
        message,
        level,
        data: safeData,
      });
    })
    .catch(() => {
      // Observability must never alter product control flow.
    });
}
