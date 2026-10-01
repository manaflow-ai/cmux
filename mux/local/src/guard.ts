// The local server drives an agent that can run commands, so only this
// server's own pages (and local tools without an Origin) may talk to it.

/** True when the request is addressed to this server by a loopback name (no DNS rebinding). */
export function hostAllowed(request: Request, port: number): boolean {
  const host = request.headers.get("host") ?? "";
  return host === `127.0.0.1:${port}` || host === `localhost:${port}`;
}

/** True for same-origin browser requests and for non-browser clients (no Origin header). */
export function originAllowed(request: Request, port: number): boolean {
  const origin = request.headers.get("origin");
  if (origin === null) return true;
  return origin === `http://127.0.0.1:${port}` || origin === `http://localhost:${port}`;
}
