import type { ExternalAccess } from "../model";

/** Strictly decode the typed daemon marker; arbitrary tool error text never creates an ask. */
export function externalAccessFromRequest(request: unknown): ExternalAccess | undefined {
  if (!request || typeof request !== "object") return undefined;
  const tool = (request as { toolCall?: unknown }).toolCall;
  if (!tool || typeof tool !== "object") return undefined;
  const meta = (tool as { _meta?: { acpmux?: { externalAccess?: unknown } } })._meta;
  const value = meta?.acpmux?.externalAccess;
  if (!value || typeof value !== "object") return undefined;
  const access = value as Partial<ExternalAccess>;
  if (
    (access.kind !== "files_and_folders" && access.kind !== "full_disk_access") ||
    typeof access.target !== "string" ||
    !access.target.startsWith("/") ||
    access.operation !== "read_text_file" ||
    access.platform !== "macos"
  )
    return undefined;
  return {
    kind: access.kind,
    target: access.target,
    operation: access.operation,
    platform: access.platform,
  };
}
