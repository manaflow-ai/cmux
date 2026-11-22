import { isVmAgentUpdatesSetting, VM_AGENT_UPDATES_SETTINGS, type VmAgentUpdatesSetting } from "./agentUpdates";
import { jsonResponse } from "./routeHelpers";

function invalidAgentUpdatesResponse(value: unknown): Response {
  return jsonResponse({
    error: "invalid_agent_updates",
    message: `agentUpdates must be one of ${VM_AGENT_UPDATES_SETTINGS.map((setting) => `"${setting}"`).join(", ")}, got ${JSON.stringify(value) ?? "undefined"}.`,
  }, 400);
}

/** The optional `agentUpdates` on a create. Omitted keeps the image's pins. */
export function parseCreateAgentUpdates(
  value: unknown,
): { readonly ok: true; readonly setting: VmAgentUpdatesSetting | undefined } | { readonly ok: false; readonly response: Response } {
  if (value === undefined || value === null) return { ok: true, setting: undefined };
  if (!isVmAgentUpdatesSetting(value)) return { ok: false, response: invalidAgentUpdatesResponse(value) };
  return { ok: true, setting: value };
}

/** `PUT /api/vm/{id}/agent-updates` body: `{ "agentUpdates": "latest" | "image" }`. */
export function parseAgentUpdatesBody(
  body: unknown,
): { readonly ok: true; readonly setting: VmAgentUpdatesSetting } | { readonly ok: false; readonly response: Response } {
  const value = body && typeof body === "object" && !Array.isArray(body)
    ? (body as Record<string, unknown>).agentUpdates
    : undefined;
  if (!isVmAgentUpdatesSetting(value)) return { ok: false, response: invalidAgentUpdatesResponse(value) };
  return { ok: true, setting: value };
}
