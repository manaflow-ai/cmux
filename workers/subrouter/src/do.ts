import { DurableObject } from "cloudflare:workers";
import { controlStatus, type SubrouterControlStatus } from "./core";
import { json } from "./http";

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
    const next = controlStatus();
    await this.ctx.storage.put(STATUS_KEY, next);
    return next;
  }
}
