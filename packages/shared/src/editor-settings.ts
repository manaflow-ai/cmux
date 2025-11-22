import { z } from "zod";
import { AuthFileSchema } from "./worker-schemas";

export const EditorSettingsUploadSchema = z.object({
  authFiles: z.array(AuthFileSchema),
  startupCommands: z.array(z.string()),
  sourceEditor: z.enum(["vscode", "cursor", "windsurf"]),
  settingsPath: z.string().optional(),
});

export type EditorSettingsUpload = z.infer<typeof EditorSettingsUploadSchema>;
