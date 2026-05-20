import { z } from "zod";
import {
  jsonResponse,
  withAuthedTypefullyApiRoute,
} from "../../../../../services/typefully/routeHelpers";
import {
  archiveTypefullyDraft,
  runTypefullyWorkflow,
  updateTypefullyDraft,
} from "../../../../../services/typefully/workflows";
import { setSpanAttributes } from "../../../../../services/telemetry";

export const dynamic = "force-dynamic";

const draftBodySchema = z.object({
  title: z.string().max(240).default("Untitled draft"),
  thread: z.array(z.string().max(10_000)).min(1).max(50).default([""]),
});

export async function PATCH(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  return withAuthedTypefullyApiRoute(
    request,
    "/api/typefully/drafts/[id]",
    { "cmux.typefully.operation": "update" },
    async ({ user, span }) => {
      const { id } = await params;
      setSpanAttributes(span, { "cmux.typefully.draft_id": id });

      const parsed = await parseDraftBody(request);
      if (!parsed.ok) return parsed.response;

      const draft = await runTypefullyWorkflow(updateTypefullyDraft({
        id,
        userId: user.id,
        draft: parsed.body,
      }));
      return jsonResponse({ draft });
    },
  );
}

export async function DELETE(
  request: Request,
  { params }: { params: Promise<{ id: string }> },
): Promise<Response> {
  return withAuthedTypefullyApiRoute(
    request,
    "/api/typefully/drafts/[id]",
    { "cmux.typefully.operation": "archive" },
    async ({ user, span }) => {
      const { id } = await params;
      setSpanAttributes(span, { "cmux.typefully.draft_id": id });
      await runTypefullyWorkflow(archiveTypefullyDraft({ id, userId: user.id }));
      return jsonResponse({ ok: true });
    },
  );
}

async function parseDraftBody(
  request: Request,
): Promise<
  | { readonly ok: true; readonly body: z.infer<typeof draftBodySchema> }
  | { readonly ok: false; readonly response: Response }
> {
  let rawBody: unknown;
  try {
    rawBody = await request.json();
  } catch {
    return {
      ok: false,
      response: jsonResponse({
        error: "invalid_json",
        message: "Draft body must be valid JSON.",
      }, 400),
    };
  }

  const parsed = draftBodySchema.safeParse(rawBody);
  if (!parsed.success) {
    return {
      ok: false,
      response: jsonResponse({
        error: "invalid_draft",
        message: "Draft body must include a title and thread.",
        issues: parsed.error.issues,
      }, 400),
    };
  }

  return { ok: true, body: parsed.data };
}
