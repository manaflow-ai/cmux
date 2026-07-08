CREATE INDEX "cloud_vm_leases_identity_cleanup_idx" ON "cloud_vm_leases" ("expires_at","created_at","id") WHERE "provider_identity_handle" is not null and "revoked_at" is null;
