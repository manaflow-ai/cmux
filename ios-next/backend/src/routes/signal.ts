import { Hono } from "hono";
import { requireUserOrHost } from "../auth";
import type { HonoEnv } from "../context";
import { randomId } from "../crypto";
import { ApiError } from "../errors";
import { signalRoom } from "../signal/client";
import { HEADER_HOST, HEADER_HOSTS, HEADER_PEER, HEADER_ROLE, HEADER_USER } from "../signal/room";

export const signalRoutes = new Hono<HonoEnv>();

signalRoutes.get("/", requireUserOrHost, async (c) => {
  if (c.req.header("upgrade")?.toLowerCase() !== "websocket") throw new ApiError("bad_request", "expected a WebSocket upgrade", 426);
  const { principal, repo } = c.var;
  const hosts = await repo.listHosts(principal.userId);
  const headers = new Headers({
    upgrade: "websocket",
    connection: "Upgrade",
    [HEADER_ROLE]: principal.kind === "host" ? "host" : "phone",
    [HEADER_USER]: principal.userId,
    [HEADER_PEER]: randomId("p"),
    [HEADER_HOSTS]: JSON.stringify(hosts.map((h) => h.id)),
  });
  if (principal.kind === "host") headers.set(HEADER_HOST, principal.hostId);
  for (const h of ["sec-websocket-key", "sec-websocket-version", "sec-websocket-protocol", "sec-websocket-extensions"]) {
    const v = c.req.header(h);
    if (v) headers.set(h, v);
  }
  return signalRoom(c.env, principal.userId).fetch("https://signal/connect", { headers });
});
