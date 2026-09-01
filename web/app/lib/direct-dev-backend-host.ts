/**
 * Next.js normally builds absolute request URLs from the address that the
 * development server binds to. A direct dev backend is behind Tailscale
 * Serve, so Next must use the forwarded Host and protocol instead.
 *
 * Keep this opt-in. SSH transport and every hosted deployment retain Next's
 * normal host handling.
 */
export function shouldTrustDirectDevBackendHost(
  environment: Record<string, string | undefined> = process.env,
): boolean {
  return environment.CMUX_DEV_BACKEND_TRANSPORT === "direct";
}
