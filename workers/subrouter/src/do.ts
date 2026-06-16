import { DurableObject } from "cloudflare:workers";
import { controlStatus, type SubrouterControlStatus } from "./core";

const STATUS_KEY = "status";

export class SubrouterControl extends DurableObject {
  async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);
    if (request.method !== "GET" || url.pathname !== "/status") {
      return json({ error: "not_found" }, 404);
    }
    return json(await this.status());
  }

  async status(): Promise<SubrouterControlStatus> {
    const existing = await this.ctx.storage.get<SubrouterControlStatus>(STATUS_KEY);
    if (existing) return existing;
    const next = controlStatus();
    await this.ctx.storage.put(STATUS_KEY, next);
    return next;
  }
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}
