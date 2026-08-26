import { z } from "zod";

import { captureCoderouterEvent } from
  "../../../../services/coderouter/analytics";
import { resolveCoderouterUsageTeam } from
  "../../../../services/coderouter/requestContext";
import { readBoundedJsonRecord } from
  "../../../../services/subrouter/boundedJson";

const MAX_BODY_BYTES = 8 * 1024;

const eventSchema = z.object({
  event: z.enum([
    "coderouter_cli_command_started",
    "coderouter_cli_command_completed",
  ]),
  properties: z.object({
    schema_version: z.literal(1),
    command: z.enum([
      "accounts",
      "help",
      "version",
      "agent",
      "add",
      "remove",
      "login",
      "logout",
      "organization",
      "upgrade",
      "doctor",
      "unknown",
    ]),
    agent: z.enum(["none", "codex", "opencode", "pi"]),
    mode: z.enum([
      "summary",
      "default",
      "routed",
      "direct",
      "interactive",
      "specified",
      "cancel",
      "unknown",
      "code",
      "device",
      "current",
      "list",
      "switch",
    ]),
    outcome: z.enum(["started", "success", "failure", "cancelled"]),
    failure_stage: z.enum([
      "none",
      "validation",
      "control_plane",
      "child_start",
      "local_io",
      "child_process",
    ]),
    exit_code_class: z.enum([
      "not_applicable",
      "success",
      "generic_failure",
      "usage",
      "launch_failure",
      "signal_or_terminated",
      "other_failure",
    ]),
    duration_bucket: z.enum([
      "not_applicable",
      "under_1s",
      "1s_to_5s",
      "5s_to_30s",
      "30s_to_2m",
      "2m_or_more",
    ]),
    execution_context: z.enum(["interactive", "headless"]),
    cli_version: z.string().regex(/^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/)
      .max(64),
  }).strict(),
}).strict();

const batchSchema = z.object({
  events: z.array(eventSchema).min(1).max(2),
}).strict();

export async function POST(request: Request): Promise<Response> {
  const contentLength = Number(request.headers.get("content-length") ?? 0);
  if (Number.isFinite(contentLength) && contentLength > MAX_BODY_BYTES) {
    return new Response(null, { status: 413 });
  }
  const resolved = await resolveCoderouterUsageTeam(request);
  if (!resolved.ok) return resolved.response;

  const bounded = await readBoundedJsonRecord(request, MAX_BODY_BYTES);
  if (!bounded.ok) return new Response(null, { status: bounded.status });
  const batch = batchSchema.safeParse(bounded.value);
  if (!batch.success) {
    return Response.json({ error: "invalid_request" }, { status: 400 });
  }
  for (const event of batch.data.events) {
    captureCoderouterEvent({
      event: event.event,
      userId: resolved.stackUserId,
      teamId: resolved.teamId,
      properties: event.properties,
    });
  }
  return new Response(null, { status: 204 });
}
