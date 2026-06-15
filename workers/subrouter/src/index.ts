// cmux Subrouter control plane.
//
// The Linux Subrouter data plane is still external. This Worker provides the
// deployable Durable Object control surface and the same CI/CD shape as the
// presence service, so the managed router lifecycle can be added behind a
// stable worker deploy path.

import { controlStatus, normalizeEndpoint } from "./core";
import { SubrouterControl } from "./do";

export { SubrouterControl };

export interface Env {
  SUBROUTER_CONTROL: DurableObjectNamespace<SubrouterControl>;
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function controlStub(env: Env): DurableObjectStub<SubrouterControl> {
  return env.SUBROUTER_CONTROL.get(env.SUBROUTER_CONTROL.idFromName("global"));
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);

    if (url.pathname === "/healthz") {
      return json({ ok: true, service: "cmux-subrouter" });
    }

    if (url.pathname === "/v1/subrouter/capabilities") {
      return json(controlStatus());
    }

    if (url.pathname === "/v1/subrouter/status") {
      if (request.method !== "GET") return json({ error: "method_not_allowed" }, 405);
      return json(await controlStub(env).status());
    }

    if (url.pathname === "/v1/subrouter/endpoint") {
      if (request.method !== "GET") return json({ error: "method_not_allowed" }, 405);
      const raw = url.searchParams.get("url") ?? "";
      const endpoint = normalizeEndpoint(raw);
      if (!endpoint) return json({ error: "invalid_url" }, 400);
      return json(endpoint);
    }

    return json({ error: "not_found" }, 404);
  },
} satisfies ExportedHandler<Env>;
