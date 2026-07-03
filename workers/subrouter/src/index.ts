// cmux Subrouter control plane.
//
// The Linux Subrouter data plane is still external. This Worker provides the
// deployable Durable Object control surface and the same CI/CD shape as the
// presence service, so the managed router lifecycle can be added behind a
// stable worker deploy path.

import { controlStatus, normalizeEndpoint } from "./core";
import { SubrouterControl } from "./do";
import { json, upstreamErrorResponse } from "./http";
import {
  consumeRateLimitResetCredit,
  fetchRateLimitResetCredits,
} from "./rate-limit-reset-credits";

export { SubrouterControl };

export interface Env {
  SUBROUTER_CONTROL: DurableObjectNamespace<SubrouterControl>;
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

    if (url.pathname === "/v1/subrouter/rate-limit-reset-credits") {
      if (request.method !== "GET") return json({ error: "method_not_allowed" }, 405);
      return await handleRateLimitResetCredits(request);
    }

    if (url.pathname === "/v1/subrouter/rate-limit-reset-credits/consume") {
      if (request.method !== "POST") return json({ error: "method_not_allowed" }, 405);
      return await handleConsumeRateLimitResetCredit(request);
    }

    return json({ error: "not_found" }, 404);
  },
} satisfies ExportedHandler<Env>;

async function handleRateLimitResetCredits(request: Request): Promise<Response> {
  const auth = extractAuthToken(request);
  if (!auth) {
    return json({ error: "missing_authorization" }, 401);
  }
  try {
    const result = await fetchRateLimitResetCredits("https://chatgpt.com", auth.token);
    return json(result);
  } catch {
    return upstreamErrorResponse();
  }
}

async function handleConsumeRateLimitResetCredit(request: Request): Promise<Response> {
  const auth = extractAuthToken(request);
  if (!auth) {
    return json({ error: "missing_authorization" }, 401);
  }
  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }
  const consumeRequest = body as { credit_id?: string; redeem_request_id?: string };
  if (!consumeRequest.credit_id || !consumeRequest.redeem_request_id) {
    return json({ error: "missing_credit_id_or_redeem_request_id" }, 400);
  }
  try {
    const result = await consumeRateLimitResetCredit("https://chatgpt.com", auth.token, {
      credit_id: consumeRequest.credit_id,
      redeem_request_id: consumeRequest.redeem_request_id,
    });
    return json(result);
  } catch {
    return upstreamErrorResponse();
  }
}

function extractAuthToken(request: Request): { token: string } | null {
  const header = request.headers.get("authorization");
  if (header) {
    return { token: header };
  }
  return null;
}
