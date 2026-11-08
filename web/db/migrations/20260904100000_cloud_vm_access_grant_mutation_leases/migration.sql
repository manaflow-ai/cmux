ALTER TABLE "cloud_vm_access_grants"
  ADD COLUMN "mutation_lease_id" uuid,
  ADD COLUMN "mutation_lease_expires_at" timestamp with time zone;

ALTER TABLE "cloud_vm_access_grants"
  ADD CONSTRAINT "cloud_vm_access_grants_mutation_lease_pair"
  CHECK (("mutation_lease_id" IS NULL) = ("mutation_lease_expires_at" IS NULL));
