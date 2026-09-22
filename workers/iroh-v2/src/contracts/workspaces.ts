import { z } from "zod";
import { identifier, revision } from "./common";

const WorkspaceRow = z.strictObject({
  id: identifier,
  name: z.string().max(512),
  index: z.number().int().nonnegative().safe(),
  focused: z.boolean(),
});

const TerminalRow = z.strictObject({
  id: identifier,
  title: z.string().max(512),
  workspaceId: identifier.nullable(),
  cwd: z.string().max(4096).nullable(),
  agent: z.string().max(128).nullable(),
});

export const WorkspaceSnapshotSchema = z.strictObject({
  workspaces: z.array(WorkspaceRow).max(4096),
  terminals: z.array(TerminalRow).max(16384),
});
export type WorkspaceSnapshot = z.infer<typeof WorkspaceSnapshotSchema>;

export const WorkspacePublishRequestSchema = z.strictObject({
  teamId: identifier,
  vmId: identifier,
  generation: identifier,
  revision,
  snapshot: WorkspaceSnapshotSchema,
  source: z.literal("vm"),
});
export type WorkspacePublishRequest = z.infer<typeof WorkspacePublishRequestSchema>;

export const VmChangedRequestSchema = z.strictObject({
  teamId: identifier,
  vmId: identifier,
  displayName: z.string().max(512).nullable(),
  slug: z.string().max(256).nullable(),
  status: z.string().max(64),
});
export type VmChangedRequest = z.infer<typeof VmChangedRequestSchema>;

export const WorkspaceSnapshotRequestSchema = z.strictObject({
  schemaId: z.literal("workspace.snapshot.v1"),
  requestId: identifier,
  vmId: identifier,
  generation: identifier,
  revision,
  snapshot: WorkspaceSnapshotSchema,
});

export const WorkspaceGetRequestSchema = z.strictObject({
  schemaId: z.literal("workspace.get.v1"),
  requestId: identifier,
  vmId: identifier,
});

export const WorkspaceListRequestSchema = z.strictObject({
  schemaId: z.literal("workspace.list.v1"),
  requestId: identifier,
});
