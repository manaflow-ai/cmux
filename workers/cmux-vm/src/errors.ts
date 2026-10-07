/**
 * Public errors. Every message is written for API clients: no provider names,
 * upstream ids, SQL or stack traces. A resource the caller cannot see is always
 * `NotFound`, whether it does not exist or belongs to another tenant.
 */
import { HttpApiSchema } from "@effect/platform";
import { Schema } from "effect";
import { Scope } from "./domain/scopes.ts";

export class Unauthorized extends Schema.TaggedError<Unauthorized>()(
  "Unauthorized",
  { message: Schema.String },
  HttpApiSchema.annotations({ status: 401 }),
) {}

export class Forbidden extends Schema.TaggedError<Forbidden>()(
  "Forbidden",
  { message: Schema.String, missingScope: Schema.optional(Scope) },
  HttpApiSchema.annotations({ status: 403 }),
) {}

export class NotFound extends Schema.TaggedError<NotFound>()(
  "NotFound",
  { message: Schema.String },
  HttpApiSchema.annotations({ status: 404 }),
) {}

export class ServiceUnavailable extends Schema.TaggedError<ServiceUnavailable>()(
  "ServiceUnavailable",
  { message: Schema.String },
  HttpApiSchema.annotations({ status: 503 }),
) {}

export const vmNotFound = () => new NotFound({ message: "VM not found" });
export const missingScope = (scope: Scope) =>
  new Forbidden({ message: `This credential lacks the ${scope} scope`, missingScope: scope });
export const unavailable = () => new ServiceUnavailable({ message: "The cmux VM service is temporarily unavailable" });

/** The request conflicts with the resource's current state (for example, starting a VM that is being deleted). */
export class Conflict extends Schema.TaggedError<Conflict>()(
  "Conflict",
  { message: Schema.String },
  HttpApiSchema.annotations({ status: 409 }),
) {}

/** The tenant's plan does not include this resource. */
export class PaymentRequired extends Schema.TaggedError<PaymentRequired>()(
  "PaymentRequired",
  { message: Schema.String },
  HttpApiSchema.annotations({ status: 402 }),
) {}

/** A tenant quota or rate limit was reached. */
export class QuotaExceeded extends Schema.TaggedError<QuotaExceeded>()(
  "QuotaExceeded",
  { message: Schema.String, retryAfterSeconds: Schema.optional(Schema.Int) },
  HttpApiSchema.annotations({ status: 429 }),
) {}

/** The endpoint is part of the published contract but not served yet. */
export class NotImplemented extends Schema.TaggedError<NotImplemented>()(
  "NotImplemented",
  { message: Schema.String },
  HttpApiSchema.annotations({ status: 501 }),
) {}

export const notImplemented = (operation: string) =>
  new NotImplemented({ message: `${operation} is not available yet` });
