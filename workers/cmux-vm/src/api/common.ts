/**
 * Schemas shared by the endpoint groups in src/api/. These modules never import
 * src/api.ts (which composes them), so the groups are defined without the
 * Authentication middleware and src/api.ts applies it when it adds them.
 */
import { HttpApiSchema, OpenApi } from "@effect/platform";
import { Schema } from "effect";

/** With a session token, names the team (tenant) the request acts for. Ignored for API keys. */
const teamHeader = { "x-cmux-team-id": Schema.optional(Schema.String.pipe(Schema.minLength(1), Schema.maxLength(128))) };

export const GroupTeamHeaders = Schema.Struct(teamHeader);

/** Retrying a create with the same idempotency key returns the first result instead of creating twice. */
export const GroupCreateHeaders = Schema.Struct({
  ...teamHeader,
  "idempotency-key": Schema.optional(Schema.String.pipe(Schema.minLength(1), Schema.maxLength(255))),
});

export const DisplayName = Schema.String.pipe(Schema.minLength(1), Schema.maxLength(100));

export const describe = (summary: string, scope: string, detail?: string) =>
  OpenApi.annotations({
    summary,
    description: detail === undefined ? `${summary}. Requires the ${scope} scope.` : `${summary}. Requires the ${scope} scope. ${detail}`,
  });

/** The request is well formed JSON but cannot be served as asked (for example, a stale page cursor). */
export class InvalidRequest extends Schema.TaggedError<InvalidRequest>()(
  "InvalidRequest",
  { message: Schema.String },
  HttpApiSchema.annotations({ status: 400 }),
) {}

/** The endpoint speaks WebSocket only and the request did not ask to upgrade. */
export class UpgradeRequired extends Schema.TaggedError<UpgradeRequired>()(
  "UpgradeRequired",
  { message: Schema.String },
  HttpApiSchema.annotations({ status: 426 }),
) {}
