CREATE TABLE "cloud_organizations" (
  "scope_id" text PRIMARY KEY,
  "owner_user_id" text NOT NULL,
  "slug" text NOT NULL,
  "created_at" timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT "cloud_organizations_slug_check" CHECK (char_length(slug) BETWEEN 1 AND 19 AND slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$')
);
CREATE UNIQUE INDEX "cloud_organizations_slug_unique" ON "cloud_organizations" ("slug");
ALTER TABLE "cloud_vm_publications" ALTER COLUMN "domain_id" DROP NOT NULL;
CREATE TABLE "cloud_vm_publication_email_grants" (
  "id" uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  "publication_id" uuid NOT NULL REFERENCES "cloud_vm_publications" ("id") ON DELETE CASCADE,
  "email" text NOT NULL,
  "expires_at" timestamptz,
  "created_at" timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT "cloud_vm_publication_email_grants_email_check" CHECK (email = lower(email) AND char_length(email) BETWEEN 3 AND 254)
);
CREATE UNIQUE INDEX "cloud_vm_publication_email_grants_unique" ON "cloud_vm_publication_email_grants" ("publication_id", "email");
