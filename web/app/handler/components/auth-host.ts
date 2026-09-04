/**
 * coderouter shares this deployment but not its sign-in options.
 *
 * The cmux Google connector asks for Drive, Gmail, and Calendar scopes so the
 * desktop app can offer those integrations. Those scopes have nothing to do
 * with routing model traffic, so coderouter offers passwordless email only.
 */
export function isCoderouterHost(host: string | null): boolean {
  const hostname = host?.split(":", 1)[0]?.toLowerCase();
  if (!hostname) return false;
  return hostname === "coderouter.dev" || hostname.endsWith(".coderouter.dev");
}
