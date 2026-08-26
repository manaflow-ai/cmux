// Runtime validation for provider JSON at the driver boundary.
//
// Provider control planes return untyped JSON; the drivers used to cast it (`as T`), which let
// a malformed response propagate `undefined` deep into workflows — the worst case was
// Freestyle exec treating a MISSING statusCode as exit-0 success. Every raw-JSON read now goes
// through a zod schema here. Schemas keep every field optional where the provider genuinely
// omits it, and validation failure raises a tagged ProviderError naming the operation instead
// of a distant undefined-property crash.
import { z } from "zod";
import { ProviderError, type ProviderId } from "./types";

// ---------------------------------------------------------------------------------------------
// Blaxel control-plane and sandbox-API responses
// ---------------------------------------------------------------------------------------------

export const BlaxelSandboxSchema = z.object({
  metadata: z
    .object({
      name: z.string().optional(),
      url: z.string().optional(),
      createdAt: z.string().optional(),
    })
    .optional(),
  spec: z
    .object({
      runtime: z
        .object({
          image: z.string().optional(),
          memory: z.number().optional(),
        })
        .optional(),
    })
    .optional(),
  state: z.string().optional(),
  status: z.string().optional(),
});
export type BlaxelSandbox = z.infer<typeof BlaxelSandboxSchema>;

export const BlaxelProcessSchema = z.object({
  pid: z.string().optional(),
  name: z.string().optional(),
  status: z.string().optional(),
  exitCode: z.number().optional(),
  stdout: z.string().optional(),
  stderr: z.string().optional(),
  logs: z.string().optional(),
});
export type BlaxelProcess = z.infer<typeof BlaxelProcessSchema>;

export const BlaxelPreviewSchema = z.object({
  metadata: z.object({ name: z.string().optional() }).optional(),
  spec: z
    .object({
      url: z.string().optional(),
      public: z.boolean().optional(),
      prefixUrl: z.string().optional(),
      customDomain: z.string().optional(),
    })
    .optional(),
});
export type BlaxelPreview = z.infer<typeof BlaxelPreviewSchema>;

/** Blaxel lists previews either as a bare array or wrapped in `{ items: [...] }`. */
export const BlaxelPreviewListSchema = z
  .union([
    z.array(z.unknown()),
    z.object({ items: z.array(z.unknown()).optional() }),
  ])
  .transform((value): BlaxelPreview[] => {
    const rawItems = Array.isArray(value) ? value : value.items ?? [];
    return rawItems.flatMap((item) => {
      const parsed = BlaxelPreviewSchema.safeParse(item);
      return parsed.success ? [parsed.data] : [];
    });
  });

export const BlaxelPreviewTokenSchema = z.object({
  spec: z.object({ token: z.string().optional() }).optional(),
});
export type BlaxelPreviewToken = z.infer<typeof BlaxelPreviewTokenSchema>;

export const BlaxelCustomDomainSchema = z.object({
  spec: z.object({ status: z.string().optional() }).optional(),
});
export type BlaxelCustomDomain = z.infer<typeof BlaxelCustomDomainSchema>;

/** For requests whose response body is ignored (filesystem PUTs, DELETEs, process starts). */
export const IgnoredResponseSchema = z.unknown();

/**
 * Validates one provider JSON payload, wrapping any mismatch in a ProviderError that names the
 * operation. `undefined` (empty response body) is passed through the schema too, so operations
 * that expect a body fail loudly on an empty 200.
 */
export function parseProviderJson<T>(
  provider: ProviderId,
  operation: string,
  schema: z.ZodType<T>,
  payload: unknown,
): T {
  const parsed = schema.safeParse(payload);
  if (!parsed.success) {
    throw new ProviderError(
      provider,
      `${operation} returned an unexpected response shape: ${parsed.error.message.slice(0, 500)}`,
    );
  }
  return parsed.data;
}

// ---------------------------------------------------------------------------------------------
// Freestyle exec responses
// ---------------------------------------------------------------------------------------------

// ResponsePostV1VmsVmIdExecAwait200: { stdout, stderr, statusCode }. statusCode is REQUIRED:
// the old cast (`(r as { statusCode?: number }).statusCode ?? 0`) turned a missing statusCode
// into exit-0 success, so a malformed or truncated exec response looked like a command that
// ran cleanly. A response without a numeric statusCode is now a validation error.
export const FreestyleExecResponseSchema = z.object({
  statusCode: z.number(),
  stdout: z.string().nullish(),
  stderr: z.string().nullish(),
});

export type FreestyleExecResult = {
  readonly exitCode: number;
  readonly stdout: string;
  readonly stderr: string;
};

export function parseFreestyleExecResponse(operation: string, payload: unknown): FreestyleExecResult {
  const parsed = parseProviderJson("freestyle", operation, FreestyleExecResponseSchema, payload);
  return {
    exitCode: parsed.statusCode,
    stdout: parsed.stdout ?? "",
    stderr: parsed.stderr ?? "",
  };
}
