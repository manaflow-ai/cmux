import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { basename } from "node:path";

type Json = Record<string, unknown>;

export interface CmuxExecution {
  exec(command: string, args: string[]): Promise<{ stdout: string; stderr: string; code: number }>;
}

function parseJson(stdout: string): Json {
  try {
    return JSON.parse(stdout) as Json;
  } catch {
    throw new Error(`cmux returned invalid JSON: ${stdout.slice(0, 300)}`);
  }
}

function firstString(value: unknown, keys: string[]): string | undefined {
  if (!value || typeof value !== "object") return undefined;
  const object = value as Json;
  for (const key of keys) {
    if (typeof object[key] === "string") return object[key] as string;
  }
  return undefined;
}

function nestedString(value: unknown, paths: string[][]): string | undefined {
  for (const path of paths) {
    let cursor: unknown = value;
    for (const segment of path) {
      if (!cursor || typeof cursor !== "object") {
        cursor = undefined;
        break;
      }
      cursor = (cursor as Json)[segment];
    }
    if (typeof cursor === "string") return cursor;
  }
  return undefined;
}

async function checked(executor: CmuxExecution, args: string[]): Promise<Json> {
  const result = await executor.exec("cmux", ["--json", ...args]);
  if (result.code !== 0) {
    throw new Error(result.stderr.trim() || `cmux ${args[0]} failed with exit code ${result.code}`);
  }
  return parseJson(result.stdout);
}

export function piCmuxExecution(pi: ExtensionAPI): CmuxExecution {
  return {
    exec: (command, args) => pi.exec(command, args),
  };
}

export async function ensureParentGroup(
  executor: CmuxExecution,
  cwd: string,
): Promise<{ groupRef: string; parentWorkspaceRef: string }> {
  const identity = await checked(executor, ["identify"]);
  const parentWorkspaceRef = nestedString(identity, [
    ["caller", "workspace_ref"],
    ["focused", "workspace_ref"],
  ]) ?? firstString(identity, ["workspace_ref"]);
  if (!parentWorkspaceRef) {
    throw new Error("cmux could not identify the parent workspace");
  }

  const existingGroup = nestedString(identity, [
    ["caller", "workspace_group_ref"],
    ["caller", "group_ref"],
    ["focused", "workspace_group_ref"],
    ["focused", "group_ref"],
  ]) ?? firstString(identity, ["workspace_group_ref", "group_ref"]);
  if (existingGroup) return { groupRef: existingGroup, parentWorkspaceRef };

  const groupName = `Pi · ${basename(cwd) || "subagents"}`;
  const created = await checked(executor, [
    "workspace-group",
    "create",
    "--name",
    groupName,
    "--cwd",
    cwd,
    "--from",
    parentWorkspaceRef,
  ]);
  const group = created.group;
  const groupRef = firstString(group, ["ref", "group_ref", "workspace_group_ref"])
    ?? firstString(created, ["group_ref", "workspace_group_ref"]);
  if (!groupRef) throw new Error("cmux created a group but did not return its reference");
  return { groupRef, parentWorkspaceRef };
}

export async function createChildWorkspace(
  executor: CmuxExecution,
  input: {
    groupRef: string;
    cwd: string;
    title: string;
    command: string;
    parentWorkspaceRef: string;
  },
): Promise<string> {
  const created = await checked(executor, [
    "new-workspace",
    "--name",
    input.title,
    "--description",
    "Pi subagent",
    "--cwd",
    input.cwd,
    "--command",
    input.command,
    "--group",
    input.groupRef,
    "--group-placement",
    "afterCurrent",
    "--group-reference",
    input.parentWorkspaceRef,
    "--focus",
    "false",
  ]);
  const workspaceRef = firstString(created, ["workspace_ref", "ref"])
    ?? firstString(created.workspace, ["workspace_ref", "ref"]);
  if (!workspaceRef) throw new Error("cmux created a workspace but did not return its reference");
  return workspaceRef;
}

export async function steerWorkspace(
  executor: CmuxExecution,
  workspaceRef: string,
  message: string,
): Promise<void> {
  await checked(executor, ["send", "--workspace", workspaceRef, message]);
  await checked(executor, ["send-key", "--workspace", workspaceRef, "enter"]);
}
