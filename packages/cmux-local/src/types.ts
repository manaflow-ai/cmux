/**
 * Types for cmux-local
 */

export interface Task {
  id: string;
  number: number;
  containerId: string;
  repoPath: string;
  repoName: string;
  prompt: string;
  terminalPort: number;
  cmuxDir: string; // Host directory for MCP communication files
  status: "starting" | "running" | "question" | "done" | "error";
  startedAt: Date;
  questions: Question[];
}

export interface MCPQuestion {
  id: string;
  question: string;
  context?: string;
  importance: "high" | "medium" | "low";
  options?: string[];
  timestamp: string;
  answered: boolean;
}

export interface MCPProgress {
  type?: "decision";
  status?: string;
  summary?: string;
  details?: string;
  decision?: string;
  reasoning?: string;
  alternatives?: string[];
  timestamp: string;
}

export interface Question {
  id: string;
  taskId: string;
  question: string;
  suggestion?: string;
  options?: string[];
  status: "open" | "answered" | "skipped";
  askedAt: Date;
  answeredAt?: Date;
  answer?: string;
}

export interface ActivityEntry {
  timestamp: Date;
  taskId: string;
  taskName: string;
  type: "decision" | "question" | "assumption" | "info" | "error";
  message: string;
}

export interface DockerContainer {
  id: string;
  name: string;
  status: string;
  labels: Record<string, string>;
  ports: Array<{ hostPort: number; containerPort: number }>;
}

export const BASE_PORT = 27182;

export function getTaskPort(taskNumber: number): number {
  return BASE_PORT + taskNumber;
}
