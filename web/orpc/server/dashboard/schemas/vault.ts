import { z } from "zod";
import type { VaultSummary } from "@/services/vault/summary";
import type {
  SerializedVaultSessionListPage,
  SerializedVaultSessionListRow,
} from "@/services/vault/sessionList";

export const summarySchema = z.object({
  sessionCount: z.number(),
  rawBytes: z.number(),
  compressedBytes: z.number(),
  lastUploadedAt: z.string().nullable(),
  agents: z.array(z.object({ agent: z.string(), sessionCount: z.number() })),
}) satisfies z.ZodType<VaultSummary>;

const sessionRowSchema = z.object({
  id: z.string(),
  agent: z.string(),
  agentSessionId: z.string(),
  relPath: z.string(),
  cwd: z.string().nullable(),
  latestSha256: z.string(),
  sizeBytes: z.number(),
  compressedSizeBytes: z.number().nullable(),
  snapshotCount: z.number(),
  firstUploadedAt: z.string(),
  lastUploadedAt: z.string(),
}) satisfies z.ZodType<SerializedVaultSessionListRow>;

export const sessionPageSchema = z.object({
  sessions: z.array(sessionRowSchema),
  nextCursor: z.string().optional(),
}) satisfies z.ZodType<SerializedVaultSessionListPage>;

const snapshotSchema = z.object({
  sha256: z.string(),
  sizeBytes: z.number(),
  compressedSizeBytes: z.number().nullable(),
  uploadedAt: z.string(),
});

export const sessionDetailSchema = z.object({
  id: z.string(),
  agent: z.string(),
  agentSessionId: z.string(),
  cwd: z.string().nullable(),
  sizeBytes: z.number(),
  compressedSizeBytes: z.number().nullable(),
  firstUploadedAt: z.string(),
  lastUploadedAt: z.string(),
  downloadUrl: z.string().nullable(),
  snapshots: z.array(snapshotSchema),
});

export const transcriptHeadSchema = z.object({
  messages: z.array(z.object({ role: z.string(), text: z.string() })),
  complete: z.boolean(),
});

export const cliAuthClientSchema = z.object({
  client: z.enum(["cmux-vault", "subrouter"]).nullable(),
});
