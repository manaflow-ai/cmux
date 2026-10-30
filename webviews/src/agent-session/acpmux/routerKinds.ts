/** Routes select a model provider; they are never agent harnesses. IDs and display names are not kinds. */
export function isModelRouterKind(kind: unknown): boolean {
  return kind === "cmux-router" || kind === "local-coderouter";
}
