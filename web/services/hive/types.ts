import { z } from "zod";

const idSchema = z.string().trim().min(1).max(160);
const labelSchema = z.string().trim().min(1).max(200);
const optionalLabelSchema = z.string().trim().min(1).max(400).optional();

export const hiveTerminalInputSchema = z.object({
  id: idSchema,
  title: labelSchema,
  cols: z.number().int().min(1).max(1000).default(80),
  rows: z.number().int().min(1).max(1000).default(24),
  output_rows: z.array(z.string().max(4000)).max(200).default([]),
});

export const hiveSpaceInputSchema = z.object({
  id: idSchema,
  title: labelSchema,
  terminals: z.array(hiveTerminalInputSchema).max(100).default([]),
});

export const hiveWorkspaceInputSchema = z.object({
  id: idSchema,
  node_id: idSchema.optional(),
  title: labelSchema,
  preview: optionalLabelSchema,
  last_activity_unix: z.number().finite().nonnegative().optional(),
  last_activity_ms: z.number().finite().nonnegative().optional(),
  last_activity: z.string().trim().min(1).max(80).optional(),
  unread: z.boolean().default(false),
  pinned: z.boolean().default(false),
  spaces: z.array(hiveSpaceInputSchema).max(100).default([]),
});

export const hiveNodeInputSchema = z.object({
  id: idSchema,
  name: labelSchema,
  subtitle: optionalLabelSchema,
  kind: z.string().trim().min(1).max(80).optional(),
  is_online: z.boolean().default(true),
  workspaces: z.array(hiveWorkspaceInputSchema).max(200).default([]),
});

export const hivePairingInputSchema = z.object({
  pairing_id: idSchema,
  pairing_secret: z.string().min(16).max(4096),
  expires_at_unix: z.number().int().positive(),
  node_id: idSchema.optional(),
  node: hiveNodeInputSchema.optional(),
});

export type HiveTerminal = z.infer<typeof hiveTerminalInputSchema>;
export type HiveSpace = z.infer<typeof hiveSpaceInputSchema>;
export type HiveWorkspace = z.infer<typeof hiveWorkspaceInputSchema>;
export type HiveNode = z.infer<typeof hiveNodeInputSchema>;
export type HivePairingInput = z.infer<typeof hivePairingInputSchema>;

export type HivePairingRecord = {
  pairing_id: string;
  pairing_secret: string;
  expires_at_unix: number;
  node_id: string | null;
  created_at_unix: number;
};

export type HivePairingSecret = {
  pairing_id: string;
  pairing_secret: string;
  expires_at_unix: number;
};

export type HiveSnapshot = {
  nodes: HiveNode[];
  workspaces: HiveWorkspace[];
};

export type HivePairingSummary = {
  pairing_id: string;
  expires_at_unix: number;
  node_id: string | null;
};

export type HiveActorAuth = {
  serviceToken: string;
};

