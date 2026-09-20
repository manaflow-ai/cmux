import { and, desc, eq, sql } from "drizzle-orm";
import { ORPCError } from "@orpc/server";
import { z } from "zod";

import { cloudDb } from "../../../db/client";
import { vaultSessions, vaultSnapshots } from "../../../db/schema";
import { isVaultEnabled } from "../../../services/vault/config";
import {
  queryVaultSessionListPage,
  serializeVaultSessionListPage,
  VAULT_SESSION_LIST_PAGE_SIZE,
} from "../../../services/vault/sessionList";
import { presignGet } from "../../../services/vault/storage";
import { fetchTranscriptHeadBatch } from "../../../services/vault/transcript-head";
import { os, requireAuth } from "../base";

const vaultOverviewRowSchema = z.object({
  agent: z.string(),
  sessionCount: z.number(),
  rawBytes: z.number(),
  compressedBytes: z.number(),
  lastUploadedAt: z.number().nullable(),
});

const vaultOverviewSchema = z.object({
  rows: z.array(vaultOverviewRowSchema),
  totals: z.object({
    sessionCount: z.number(),
    rawBytes: z.number(),
    compressedBytes: z.number(),
    lastUploadedAt: z.number().nullable(),
  }),
});

export const vaultOverviewProcedure = os
  .route({
    method: "GET",
    path: "/dashboard/vault/overview",
    operationId: "dashboard.vault.overview",
    summary: "Get the authenticated user's Vault usage",
    tags: ["Dashboard"],
    successStatus: 200,
  })
  .output(vaultOverviewSchema)
  .use(requireAuth)
  .handler(async ({ context }) => {
    if (!isVaultEnabled()) throw new ORPCError("NOT_FOUND");
    const rows = await cloudDb()
      .select({
        agent: vaultSessions.agent,
        sessionCount: sql<number>`count(*)::int`,
        rawBytes: sql<number>`coalesce(sum(${vaultSessions.sizeBytes}), 0)::double precision`,
        compressedBytes: sql<number>`coalesce(sum(coalesce(${vaultSessions.compressedSizeBytes}, 0)), 0)::double precision`,
        lastUploadedAt: sql<Date | null>`max(${vaultSessions.lastUploadedAt})`,
      })
      .from(vaultSessions)
      .where(eq(vaultSessions.userId, context.user.id))
      .groupBy(vaultSessions.agent);
    const totals = rows.reduce(
      (acc, row) => ({
        sessionCount: acc.sessionCount + row.sessionCount,
        rawBytes: acc.rawBytes + row.rawBytes,
        compressedBytes: acc.compressedBytes + row.compressedBytes,
        lastUploadedAt: acc.lastUploadedAt && row.lastUploadedAt
          ? acc.lastUploadedAt > row.lastUploadedAt ? acc.lastUploadedAt : row.lastUploadedAt
          : acc.lastUploadedAt ?? row.lastUploadedAt,
      }),
      { sessionCount: 0, rawBytes: 0, compressedBytes: 0, lastUploadedAt: null as Date | null },
    );
    return {
      rows: rows.map((row) => ({ ...row, lastUploadedAt: row.lastUploadedAt?.getTime() ?? null })),
      totals: { ...totals, lastUploadedAt: totals.lastUploadedAt?.getTime() ?? null },
    };
  });

const vaultSessionListInputSchema = z.object({
  q: z.string().optional(),
  cursor: z.string().optional(),
  before: z.string().optional(),
});

export const vaultSessionListProcedure = os
  .route({
    method: "GET",
    path: "/dashboard/vault/sessions",
    operationId: "dashboard.vault.sessions",
    summary: "List the authenticated user's Vault sessions",
    tags: ["Dashboard"],
    successStatus: 200,
  })
  .input(vaultSessionListInputSchema)
  .output(z.object({
    sessions: z.array(z.object({
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
    })),
    nextCursor: z.string().optional(),
  }))
  .use(requireAuth)
  .handler(async ({ context, input }) => {
    if (!isVaultEnabled()) throw new ORPCError("NOT_FOUND");
    const serialized = serializeVaultSessionListPage(await queryVaultSessionListPage(cloudDb(), {
      userId: context.user.id,
      q: input.q,
      cursor: input.cursor ?? input.before ?? null,
      limit: VAULT_SESSION_LIST_PAGE_SIZE,
    }));
    return {
      sessions: [...serialized.sessions],
      ...(serialized.nextCursor ? { nextCursor: serialized.nextCursor } : {}),
    };
  });

const vaultSessionDetailInputSchema = z.object({ id: z.string() });
const vaultSessionDetailSchema = z.object({
  id: z.string(),
  agent: z.string(),
  agentSessionId: z.string(),
  relPath: z.string(),
  cwd: z.string().nullable(),
  latestSha256: z.string(),
  sizeBytes: z.number(),
  compressedSizeBytes: z.number().nullable(),
  firstUploadedAt: z.string(),
  lastUploadedAt: z.string(),
  downloadUrl: z.string().nullable(),
  snapshots: z.array(z.object({
    sha256: z.string(),
    sizeBytes: z.number(),
    compressedSizeBytes: z.number().nullable(),
    uploadedAt: z.string(),
  })),
  messages: z.array(z.object({ role: z.string(), text: z.string() })),
  transcriptComplete: z.boolean(),
});

export const vaultSessionDetailProcedure = os
  .route({
    method: "GET",
    path: "/dashboard/vault/sessions/{id}",
    operationId: "dashboard.vault.session",
    summary: "Get an authenticated Vault session",
    tags: ["Dashboard"],
    successStatus: 200,
  })
  .input(vaultSessionDetailInputSchema)
  .output(vaultSessionDetailSchema)
  .use(requireAuth)
  .handler(async ({ context, input }) => {
    if (!isVaultEnabled() || !UUID_RE.test(input.id)) throw new ORPCError("NOT_FOUND");
    const db = cloudDb();
    const [session] = await db
      .select()
      .from(vaultSessions)
      .where(and(eq(vaultSessions.id, input.id), eq(vaultSessions.userId, context.user.id)))
      .limit(1);
    if (!session) throw new ORPCError("NOT_FOUND");
    const snapshots = await db
      .select({
        sha256: vaultSnapshots.sha256,
        sizeBytes: vaultSnapshots.sizeBytes,
        compressedSizeBytes: vaultSnapshots.compressedSizeBytes,
        uploadedAt: vaultSnapshots.uploadedAt,
      })
      .from(vaultSnapshots)
      .where(eq(vaultSnapshots.sessionId, session.id))
      .orderBy(desc(vaultSnapshots.uploadedAt));

    let downloadUrl: string | null = null;
    let messages: readonly { role: string; text: string }[] = [];
    let transcriptComplete = false;
    try {
      downloadUrl = await presignGet(session.latestObjectKey);
      const head = await fetchTranscriptHeadBatch(downloadUrl, { objectKey: session.latestObjectKey });
      messages = head.messages;
      transcriptComplete = head.complete;
    } catch {
      // Metadata remains useful when object storage or transcript parsing is unavailable.
    }
    return {
      id: session.id,
      agent: session.agent,
      agentSessionId: session.agentSessionId,
      relPath: session.relPath,
      cwd: session.cwd,
      latestSha256: session.latestSha256,
      sizeBytes: session.sizeBytes,
      compressedSizeBytes: session.compressedSizeBytes,
      firstUploadedAt: session.firstUploadedAt.toISOString(),
      lastUploadedAt: session.lastUploadedAt.toISOString(),
      downloadUrl,
      snapshots: snapshots.map((snapshot) => ({ ...snapshot, uploadedAt: snapshot.uploadedAt.toISOString() })),
      messages: [...messages],
      transcriptComplete,
    };
  });

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;
