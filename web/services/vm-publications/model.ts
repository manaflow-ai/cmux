import * as Data from "effect/Data";
import {
  cloudVmDomains,
  cloudVmPublications,
  cloudVms,
} from "../../db/schema";

export type CloudVmPublicationTarget = {
  readonly publication: typeof cloudVmPublications.$inferSelect;
  readonly domain: typeof cloudVmDomains.$inferSelect | null;
  readonly vm: typeof cloudVms.$inferSelect;
};

export class PublicationNotFoundError extends Data.TaggedError(
  "PublicationNotFoundError",
)<{
  readonly resource: "domain" | "publication" | "vm";
}> {}

export type PublicationConflictReason =
  | "organization_slug_reserved"
  | "organization_slug_taken"
  | "invalid_organization_slug"
  | "hostname_taken"
  | "domain_in_use"
  | "provider_verification_in_use"
  | "provider_rule_in_use"
  | "invalid_access_policy"
  | "publication_not_active"
  | "publication_revision_changed"
  | "vm_publication_frozen"
  | "publication_operation_lost"
  | "forward_auth_bootstrap_lost"
  | "auth_transaction_limit";

export class PublicationConflictError extends Data.TaggedError(
  "PublicationConflictError",
)<{
  readonly reason: PublicationConflictReason;
}> {}
