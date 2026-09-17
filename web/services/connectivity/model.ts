import { IrohInvalidInputError } from "../iroh/errors";

export const CONNECTIVITY_PROTOCOL_VERSION = 2;

export type ConnectivitySyncRequest = {
  readonly protocol_version: typeof CONNECTIVITY_PROTOCOL_VERSION;
  readonly known_revision: number | null;
};

export function parseConnectivitySyncRequest(value: unknown): ConnectivitySyncRequest {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new IrohInvalidInputError({ code: "invalid_connectivity_sync" });
  }
  const record = value as Record<string, unknown>;
  const keys = Object.keys(record);
  if (
    keys.some((key) => key !== "protocol_version" && key !== "known_revision")
    || record.protocol_version !== CONNECTIVITY_PROTOCOL_VERSION
  ) {
    throw new IrohInvalidInputError({ code: "invalid_connectivity_sync" });
  }
  const knownRevision = record.known_revision;
  if (
    knownRevision !== null
    && (
      !Number.isSafeInteger(knownRevision)
      || (knownRevision as number) < 0
    )
  ) {
    throw new IrohInvalidInputError({ code: "invalid_connectivity_sync" });
  }
  return {
    protocol_version: CONNECTIVITY_PROTOCOL_VERSION,
    known_revision: knownRevision as number | null,
  };
}
