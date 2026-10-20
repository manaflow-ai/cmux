import { IrohInvalidInputError } from "./errors";

export const IROH_DISCOVERY_PAGE_SIZE = 128;
export const IROH_LEGACY_DISCOVERY_PAGE_SIZE = 256;
const IROH_DISCOVERY_CURSOR_MAX_BYTES = 256;

export type IrohDiscoveryCursor = {
  readonly generation: number;
  readonly afterBindingId: string;
};

export type IrohDiscoveryRequest = {
  readonly pageSize: number;
  readonly cursor?: IrohDiscoveryCursor;
  readonly paginated: boolean;
};

export function legacyIrohDiscoveryRequest(): IrohDiscoveryRequest {
  return {
    pageSize: IROH_LEGACY_DISCOVERY_PAGE_SIZE,
    paginated: false,
  };
}

export function parseIrohDiscoveryRequest(value: unknown): IrohDiscoveryRequest {
  if (value === undefined) return legacyIrohDiscoveryRequest();
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new IrohInvalidInputError({ code: "invalid_discovery_page_size" });
  }
  const request = value as Record<string, unknown>;
  if (Object.keys(request).some((key) => key !== "pageSize" && key !== "cursor")) {
    throw new IrohInvalidInputError({ code: "invalid_discovery_page_size" });
  }
  const pageSize = canonicalPositiveInteger(request.pageSize);
  if (pageSize === null || pageSize > IROH_DISCOVERY_PAGE_SIZE) {
    throw new IrohInvalidInputError({ code: "invalid_discovery_page_size" });
  }
  return {
    pageSize,
    ...(request.cursor === undefined
      ? {}
      : { cursor: decodeIrohDiscoveryCursor(request.cursor) }),
    paginated: true,
  };
}

export function encodeIrohDiscoveryCursor(cursor: IrohDiscoveryCursor): string {
  assertCursor(cursor);
  return Buffer.from(JSON.stringify({
    v: 1,
    g: cursor.generation,
    a: cursor.afterBindingId,
  }), "utf8").toString("base64url");
}

export function decodeIrohDiscoveryCursor(value: unknown): IrohDiscoveryCursor {
  if (
    typeof value !== "string" ||
    value.length === 0 ||
    value.length > IROH_DISCOVERY_CURSOR_MAX_BYTES ||
    !/^[A-Za-z0-9_-]+$/.test(value)
  ) {
    throw new IrohInvalidInputError({ code: "invalid_discovery_cursor" });
  }
  let parsed: unknown;
  try {
    const bytes = Buffer.from(value, "base64url");
    if (
      bytes.length === 0 ||
      bytes.length > IROH_DISCOVERY_CURSOR_MAX_BYTES ||
      bytes.toString("base64url") !== value
    ) {
      throw new Error("non-canonical cursor");
    }
    parsed = JSON.parse(bytes.toString("utf8"));
  } catch {
    throw new IrohInvalidInputError({ code: "invalid_discovery_cursor" });
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
    throw new IrohInvalidInputError({ code: "invalid_discovery_cursor" });
  }
  const record = parsed as Record<string, unknown>;
  if (
    Object.keys(record).length !== 3 ||
    record.v !== 1 ||
    !Number.isSafeInteger(record.g) ||
    (record.g as number) < 1 ||
    (record.g as number) > 2_147_483_647 ||
    !isCanonicalUUID(record.a)
  ) {
    throw new IrohInvalidInputError({ code: "invalid_discovery_cursor" });
  }
  return {
    generation: record.g as number,
    afterBindingId: record.a as string,
  };
}

function canonicalPositiveInteger(value: unknown): number | null {
  if (typeof value === "number") {
    return Number.isSafeInteger(value) && value > 0 ? value : null;
  }
  if (
    typeof value !== "string" ||
    !/^[1-9][0-9]{0,2}$/.test(value)
  ) {
    return null;
  }
  const parsed = Number(value);
  return Number.isSafeInteger(parsed) && String(parsed) === value ? parsed : null;
}

function assertCursor(cursor: IrohDiscoveryCursor): void {
  if (
    !Number.isSafeInteger(cursor.generation) ||
    cursor.generation < 1 ||
    cursor.generation > 2_147_483_647 ||
    !isCanonicalUUID(cursor.afterBindingId)
  ) {
    throw new IrohInvalidInputError({ code: "invalid_discovery_cursor" });
  }
}

function isCanonicalUUID(value: unknown): value is string {
  return typeof value === "string" &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(value);
}
