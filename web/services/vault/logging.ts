export function logVaultStorageError(
  operation: string,
  objectKey: string,
  error: unknown,
): void {
  console.error("vault.storage.operation_failed", { operation, objectKey }, error);
}

export function logVaultQuotaError(operation: string, error: unknown): void {
  console.error(
    "vault.quota.operation_failed",
    { operation, objectKey: "not_applicable" },
    error,
  );
}
