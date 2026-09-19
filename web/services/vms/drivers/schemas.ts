// Runtime validation of provider responses at the driver boundary.
import { z } from "zod";
import { ProviderError, type ProviderId } from "./types";

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

// The public Freestyle API returns null when a command times out. Missing or
// malformed statusCode is a provider error; explicit null remains exit 124.
export const FreestyleExecResponseSchema = z.object({
  statusCode: z.number().nullable(),
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
    exitCode: parsed.statusCode ?? 124,
    stdout: parsed.stdout ?? "",
    stderr: parsed.stderr ?? "",
  };
}
