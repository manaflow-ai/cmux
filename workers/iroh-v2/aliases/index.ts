/**
 * Compatibility entrypoint for clients that still use the pre-rename Worker
 * hostname. Service bindings keep this forwarding in Cloudflare, so WebSocket
 * upgrades and request bodies reach the canonical Worker without creating a
 * second Durable Object namespace.
 */
export default {
  fetch(request: Request, env: { CANONICAL: Fetcher }): Promise<Response> {
    return env.CANONICAL.fetch(request);
  },
};
