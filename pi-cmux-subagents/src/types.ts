export type AgentType = "Explore" | "Plan" | "reviewer" | "worker" | "general-purpose";
export type RunStatus = "running" | "completed" | "failed";

export interface ChildResult {
  id: string;
  status: Exclude<RunStatus, "running">;
  summary?: string;
  error?: string;
  finishedAt: string;
}

export interface RunRecord {
  id: string;
  description: string;
  agentType: AgentType;
  cwd: string;
  groupRef: string;
  workspaceRef: string;
  resultPath: string;
  status: RunStatus;
  startedAt: string;
}

export interface ChildConfig {
  id: string;
  task: string;
  description: string;
  agentType: AgentType;
  model?: string;
  thinking?: string;
  resultPath: string;
  childExtensionPath: string;
}
