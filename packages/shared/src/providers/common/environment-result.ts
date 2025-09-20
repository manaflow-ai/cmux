import type { AuthFile } from "../../worker-schemas.js";

export interface EnvironmentResult {
  files: AuthFile[];
  env: Record<string, string>;
  startupCommands?: string[];
}

export type EnvironmentContext = {
  taskRunId: string;
  prompt: string;
  taskRunJwt: string;
};
