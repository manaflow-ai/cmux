// Zod request schemas for the VM REST bodies. These replace the hand-rolled
// typeof validation in the route files. Behavior contract: every accepted and
// rejected input, byte-bound limit, and error envelope stays identical to the
// previous inline checks — the schemas exist to make the contract explicit,
// not to change it. Route-level concerns (JSON parse errors, empty-body
// defaults, header/query checks) stay in the routes because their copy is
// operation-specific.

import { z } from "zod";
import type { ProviderId } from "./drivers";
import { jsonResponse, vmErrorResponse } from "./routeHelpers";

export type ParsedVmBody<T> =
  | { readonly ok: true; readonly body: T }
  | { readonly ok: false; readonly response: Response };

export const VM_PROVIDER_IDS = ["e2b", "freestyle", "daytona", "blaxel"] as const;
export const vmProviderIdSchema = z.enum(VM_PROVIDER_IDS);

/** stringField equivalent: trimmed non-empty string, everything else silently undefined. */
export function vmOptionalTrimmedString(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const trimmed = value.trim();
  return trimmed ? trimmed : undefined;
}

// ---------------------------------------------------------------------------
// POST /api/vm (create)
// ---------------------------------------------------------------------------

export const VM_CREATE_MIN_MEMORY_MB = 512;

const vmCreateBodyShape = z.looseObject({
  image: z.string().optional(),
  provider: z.string().optional(),
  // `billingTeamId: null` is ignored (falls through to `teamId`); a null
  // `teamId` is rejected like any other non-string.
  billingTeamId: z.string().nullable().optional(),
  teamId: z.string().optional(),
  persistentHome: z.boolean().optional(),
  perMachineHome: z.boolean().optional(),
  memoryMb: z.int().min(VM_CREATE_MIN_MEMORY_MB).optional(),
});

export type VmCreateBody = {
  readonly image?: string;
  readonly provider?: ProviderId;
  readonly billingTeamId?: string;
  readonly persistentHome: boolean;
  readonly perMachineHome: boolean;
  readonly memoryMb?: number;
};

export function vmInvalidTeamIdResponse(): Response {
  return vmErrorResponse({
    error: "vm_invalid_request",
    status: 400,
    message: "`teamId` must be a non-empty string when provided.",
    action: "Use a team id from `cmux auth status`, or omit `teamId` when the signed-in account has one team.",
    details: { field: "teamId" },
  });
}

export function parseVmCreateBody(candidate: Record<string, unknown>): ParsedVmBody<VmCreateBody> {
  const result = vmCreateBodyShape.safeParse(candidate);
  const issueFields = new Set(
    result.success ? [] : result.error.issues.map((issue) => String(issue.path[0] ?? "")),
  );
  // Field precedence matches the previous inline checks exactly.
  if (issueFields.has("image")) {
    return invalid(vmErrorResponse({
      error: "vm_invalid_request",
      status: 400,
      message: "`image` must be a string when provided.",
      action: "Remove `image` to use the default Cloud VM image, or pass a supported Cloud VM image id.",
      details: { field: "image" },
    }));
  }
  if (issueFields.has("provider")) {
    return invalid(vmErrorResponse({
      error: "vm_invalid_request",
      status: 400,
      message: "Cloud VM service override must be a string when provided.",
      action: "Remove the override to use the default Cloud VM service.",
      details: { field: "provider" },
    }));
  }
  if (
    typeof candidate.provider === "string" &&
    !vmProviderIdSchema.safeParse(candidate.provider).success
  ) {
    return invalid(vmErrorResponse({
      error: "vm_invalid_provider",
      status: 400,
      message: "Unsupported Cloud VM service override.",
      action: "Remove the override to use the default Cloud VM service.",
      details: { field: "provider" },
    }));
  }
  if (issueFields.has("billingTeamId") || issueFields.has("teamId")) {
    return invalid(vmInvalidTeamIdResponse());
  }
  if (issueFields.has("persistentHome")) {
    return invalid(vmErrorResponse({
      error: "vm_invalid_request",
      status: 400,
      message: "`persistentHome` must be a boolean when provided.",
      action: "Omit `persistentHome`, or send `true` to mount the per-user persistent home volume.",
      details: { field: "persistentHome" },
    }));
  }
  if (issueFields.has("perMachineHome")) {
    return invalid(vmErrorResponse({
      error: "vm_invalid_request",
      status: 400,
      message: "`perMachineHome` must be a boolean when provided.",
      action: "Omit `perMachineHome`, or send `true` to give the new machine its own persistent home volume.",
      details: { field: "perMachineHome" },
    }));
  }
  if (issueFields.has("memoryMb")) {
    return invalid(vmErrorResponse({
      error: "vm_invalid_request",
      status: 400,
      message: `\`memoryMb\` must be an integer of at least ${VM_CREATE_MIN_MEMORY_MB} when provided.`,
      action: "Omit `memoryMb` for the plan default, or send a larger integer memory size in MB.",
      details: { field: "memoryMb", minimumMemoryMb: VM_CREATE_MIN_MEMORY_MB },
    }));
  }
  if (!result.success) {
    // Unreachable: every schema field is mapped above. Fail closed anyway.
    return invalid(vmErrorResponse({
      error: "vm_invalid_request",
      status: 400,
      message: "Cloud VM create request had an invalid field.",
      action: "Send `{}` for the default VM, or include only documented fields such as `image` and `teamId`.",
    }));
  }
  const data = result.data;
  const bodyBillingTeamId = data.billingTeamId ?? data.teamId;
  if (typeof bodyBillingTeamId === "string" && bodyBillingTeamId.trim().length === 0) {
    return invalid(vmInvalidTeamIdResponse());
  }
  return {
    ok: true,
    body: {
      image: data.image,
      provider: data.provider as ProviderId | undefined,
      billingTeamId: typeof bodyBillingTeamId === "string" ? bodyBillingTeamId.trim() : undefined,
      persistentHome: data.persistentHome === true,
      perMachineHome: data.perMachineHome === true,
      memoryMb: data.memoryMb,
    },
  };
}

// ---------------------------------------------------------------------------
// POST /api/vm/base/{open,reset}
// ---------------------------------------------------------------------------

// Base tolerates null everywhere; provider is enum-checked on the trimmed value.
const vmBaseNullishString = z.string().nullish();

const vmBaseBodyShape = z.looseObject({
  name: vmBaseNullishString,
  image: vmBaseNullishString,
  provider: vmBaseNullishString,
  reason: vmBaseNullishString,
});

export type VmBaseBody = {
  readonly name?: string;
  readonly image?: string;
  readonly provider?: ProviderId;
  readonly billingTeamId?: string;
  readonly reason?: string | null;
};

export function parseVmBaseBody(candidate: Record<string, unknown>): ParsedVmBody<VmBaseBody> {
  const result = vmBaseBodyShape.safeParse(candidate);
  const issueFields = new Set(
    result.success ? [] : result.error.issues.map((issue) => String(issue.path[0] ?? "")),
  );
  const bodyBillingTeamId = candidate.billingTeamId ?? candidate.teamId;
  const stringFieldError = (field: string): ParsedVmBody<VmBaseBody> =>
    invalid(vmErrorResponse({
      error: "vm_invalid_request",
      status: 400,
      message: `\`${field}\` must be a string when provided.`,
      action: "Remove the invalid field and retry.",
      details: { field },
    }));
  // Same field order as the previous inline loop.
  if (issueFields.has("name")) return stringFieldError("name");
  if (issueFields.has("image")) return stringFieldError("image");
  if (issueFields.has("provider")) return stringFieldError("provider");
  if (
    bodyBillingTeamId !== undefined &&
    bodyBillingTeamId !== null &&
    typeof bodyBillingTeamId !== "string"
  ) {
    return stringFieldError("billingTeamId");
  }
  if (issueFields.has("reason")) return stringFieldError("reason");
  if (!result.success) {
    // Unreachable: every schema field is mapped above. Fail closed anyway.
    return stringFieldError("body");
  }
  const provider = typeof result.data.provider === "string" ? result.data.provider.trim() : undefined;
  if (provider && !vmProviderIdSchema.safeParse(provider).success) {
    return invalid(vmErrorResponse({
      error: "vm_invalid_provider",
      status: 400,
      message: "Unsupported Cloud VM service override.",
      action: "Remove the override to use the default Cloud VM service.",
      details: { field: "provider" },
    }));
  }
  return {
    ok: true,
    body: {
      name: vmOptionalTrimmedString(result.data.name),
      image: vmOptionalTrimmedString(result.data.image),
      provider: (provider || undefined) as ProviderId | undefined,
      billingTeamId: vmOptionalTrimmedString(bodyBillingTeamId),
      reason: vmOptionalTrimmedString(result.data.reason) ?? null,
    },
  };
}

// ---------------------------------------------------------------------------
// POST /api/vm/[id]/exec
// ---------------------------------------------------------------------------

// Clamp the timeout so a client can't tie up provider quota on a runaway exec.
// Upper bound matches the provider defaults (15 min on Freestyle); negative /
// non-number values fall back to 30s.
export const VM_EXEC_MAX_TIMEOUT_MS = 15 * 60 * 1000;
export const VM_EXEC_DEFAULT_TIMEOUT_MS = 30_000;

const vmExecBodyShape = z.looseObject({
  command: z
    .string()
    .transform((value) => value.trim())
    .refine((value) => value.length > 0),
  timeoutMs: z.unknown().optional().transform((raw) =>
    typeof raw === "number" && Number.isFinite(raw) && raw > 0
      ? Math.min(Math.floor(raw), VM_EXEC_MAX_TIMEOUT_MS)
      : VM_EXEC_DEFAULT_TIMEOUT_MS
  ),
});

export type VmExecBody = {
  readonly command: string;
  readonly timeoutMs: number;
};

export function parseVmExecBody(candidate: Record<string, unknown>): ParsedVmBody<VmExecBody> {
  const result = vmExecBodyShape.safeParse(candidate);
  if (!result.success) {
    // Only `command` can fail: missing, non-string, or blank after trimming.
    return invalid(vmErrorResponse({
      error: "vm_invalid_command",
      status: 400,
      message: "`command` is required and must be a non-empty string.",
      action: "Pass a shell command, for example `cmux vm exec <id> -- uname -a`.",
      details: { field: "command" },
    }));
  }
  return { ok: true, body: { command: result.data.command, timeoutMs: result.data.timeoutMs } };
}

// ---------------------------------------------------------------------------
// Client identifiers (attach-endpoint, sessions)
// ---------------------------------------------------------------------------

const VM_CLIENT_IDENTIFIER_PATTERN = /^[A-Za-z0-9._:-]{1,128}$/;

const vmClientIdentifierSchema = z
  .string()
  .transform((value) => value.trim())
  .pipe(z.string().regex(VM_CLIENT_IDENTIFIER_PATTERN));

/**
 * Tolerant by design: non-strings and blank strings are silently dropped
 * (same as before); only a non-blank string that fails the 1-128 char
 * identifier pattern is rejected.
 */
export function optionalVmClientIdentifier(
  value: unknown,
  fieldName: string,
):
  | { readonly ok: true; readonly value: string | undefined }
  | { readonly ok: false; readonly message: string } {
  if (typeof value !== "string") return { ok: true, value: undefined };
  const trimmed = value.trim();
  if (!trimmed) return { ok: true, value: undefined };
  const parsed = vmClientIdentifierSchema.safeParse(value);
  if (!parsed.success) {
    return {
      ok: false,
      message: `${fieldName} must be 1-128 characters of letters, numbers, dot, underscore, colon, or dash`,
    };
  }
  return { ok: true, value: parsed.data };
}

export function vmInvalidClientIdentifierResponse(error: string, message: string): Response {
  return jsonResponse({ error, message }, 400);
}

// ---------------------------------------------------------------------------
// PATCH /api/vm/[id] (rename)
// ---------------------------------------------------------------------------

export const VM_DISPLAY_NAME_MAX_LENGTH = 64;

const CONTROL_CHARS = /[\u0000-\u001f\u007f]/;

const vmDisplayNameStringSchema = z
  .string()
  .transform((value) => value.trim())
  .refine((value) => value.length <= VM_DISPLAY_NAME_MAX_LENGTH)
  .refine((value) => !CONTROL_CHARS.test(value))
  .transform((value) => (value.length === 0 ? null : value));

/** null clears the label; a printable string up to 64 chars sets it; undefined = invalid. */
export function normalizeVmDisplayName(raw: unknown): string | null | undefined {
  if (raw === null) return null;
  if (typeof raw !== "string") return undefined;
  const parsed = vmDisplayNameStringSchema.safeParse(raw);
  return parsed.success ? parsed.data : undefined;
}

// ---------------------------------------------------------------------------
// Provider override for restore (tolerant string field + enum)
// ---------------------------------------------------------------------------

export function parseVmProviderOverrideField(
  value: unknown,
): { readonly ok: true; readonly provider?: ProviderId } | { readonly ok: false; readonly response: Response } {
  const trimmed = vmOptionalTrimmedString(value);
  if (!trimmed) return { ok: true };
  const parsed = vmProviderIdSchema.safeParse(trimmed);
  if (parsed.success) return { ok: true, provider: parsed.data };
  return {
    ok: false,
    response: vmErrorResponse({
      error: "vm_invalid_provider",
      status: 400,
      message: "Unsupported Cloud VM service override.",
      action: "Use the default Cloud VM service, or pass a supported provider.",
      details: { field: "provider" },
    }),
  };
}

function invalid<T>(response: Response): ParsedVmBody<T> {
  return { ok: false, response };
}
