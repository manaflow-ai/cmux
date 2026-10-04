// File transfers (`cloud.file.push`, `cloud.file.pull`) after C10. Stub for the red tests.
export interface FileTransfer {
  transfer: string;
  machine: string;
  direction: "push" | "pull";
  path: string;
  state: "running" | "done" | "failed";
  bytes?: number;
  error?: string;
}
