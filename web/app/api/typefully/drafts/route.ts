import { z } from "zod";
import {
  jsonResponse,
  withAuthedTypefullyApiRoute,
} from "../../../../services/typefully/routeHelpers";
import {
  createTypefullyDraft,
  listTypefullyDrafts,
  runTypefullyWorkflow,
} from "../../../../services/typefully/workflows";
import { setSpanAttributes } from "../../../../services/telemetry";

export const dynamic = "force-dynamic";

const draftBodySchema = z.object({
  title: z.string().max(240).default("Untitled draft"),
  thread: z.array(z.string().max(10_000)).min(1).max(50).default([""]),
});

export async function GET(request: Request): Promise<Response> {
  return withAuthedTypefullyApiRoute(
    request,
    "/api/typefully/drafts",
    { "cmux.typefully.operation": "list" },
    async ({ user, span }) => {
      const drafts = await runTypefullyWorkflow(listTypefullyDrafts(user.id));
      setSpanAttributes(span, { "cmux.typefully.draft_count": drafts.length });
      return jsonResponse({ drafts });
    },
  );
}

export async function POST(request: Request): Promise<Response> {
  return withAuthedTypefullyApiRoute(
    request,
    "/api/typefully/drafts",
    { "cmux.typefully.operation": "create" },
    async ({ user, span }) => {
      const parsed = await parseDraftBody(request);
      if (!parsed.ok) return parsed.response;

      const draft = await runTypefullyWorkflow(createTypefullyDraft({
        userId: user.id,
        userEmail: user.email,
        draft: parsed.body,
      }));
      setSpanAttributes(span, { "cmux.typefully.draft_id": draft.id });
      return jsonResponse({ draft }, 201);
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
