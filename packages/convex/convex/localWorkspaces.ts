import { deriveRepoBaseName } from "@cmux/shared/utils/derive-repo-base-name";
import {
  generateWorkspaceName,
  workspaceSequenceToName,
} from "@cmux/shared/utils/generate-workspace-name";
import { v } from "convex/values";
import { resolveTeamIdLoose } from "../_shared/team";
import { authMutation, authQuery } from "./users/utils";

const DEFAULT_AGENT_NAME = "local-workspace";

const DEFAULT_WORKSPACE_DESCRIPTOR = ({
  workspaceName,
  projectFullName,
  branch,
}: {
  workspaceName: string;
  projectFullName?: string | null;
  branch?: string | null;
}) => {
  const descriptorBase = projectFullName
    ? `Local workspace ${workspaceName} (${projectFullName})`
    : `Local workspace ${workspaceName}`;
  if (!branch) {
    return descriptorBase;
  }
  const trimmedBranch = branch.trim();
  return trimmedBranch ? `${descriptorBase} [${trimmedBranch}]` : descriptorBase;
};

export const nextSequence = authQuery({
  args: {
    teamSlugOrId: v.string(),
  },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);

    const existingSetting = await ctx.db
      .query("workspaceSettings")
      .withIndex("by_team_user", (q) =>
        q.eq("teamId", teamId).eq("userId", userId),
      )
      .first();

    const sequence = existingSetting?.nextLocalWorkspaceSequence ?? 0;
    return {
      sequence,
      suffix: workspaceSequenceToName(sequence),
    };
  },
});

export const reserve = authMutation({
  args: {
    teamSlugOrId: v.string(),
    projectFullName: v.optional(v.string()),
    repoUrl: v.optional(v.string()),
    branch: v.optional(v.string()),
  },
  handler: async (ctx, args) => {
    const userId = ctx.identity.subject;
    const teamId = await resolveTeamIdLoose(ctx, args.teamSlugOrId);
    const { projectFullName, repoUrl, branch } = args;

    const existingSetting = await ctx.db
      .query("workspaceSettings")
      .withIndex("by_team_user", (q) =>
        q.eq("teamId", teamId).eq("userId", userId),
      )
      .first();

    const now = Date.now();
    const sequence = existingSetting?.nextLocalWorkspaceSequence ?? 0;
    const repoName = deriveRepoBaseName({ projectFullName, repoUrl });
    const workspaceName = generateWorkspaceName({ repoName, sequence });
    const descriptor = DEFAULT_WORKSPACE_DESCRIPTOR({
      workspaceName,
      projectFullName,
      branch,
    });

    if (existingSetting) {
      await ctx.db.patch(existingSetting._id, {
        nextLocalWorkspaceSequence: sequence + 1,
        updatedAt: now,
      });
    } else {
      await ctx.db.insert("workspaceSettings", {
        worktreePath: undefined,
        autoPrEnabled: undefined,
        nextLocalWorkspaceSequence: sequence + 1,
        createdAt: now,
        updatedAt: now,
        userId,
        teamId,
      });
    }

    const taskId = await ctx.db.insert("tasks", {
      text: descriptor,
      description: descriptor,
      projectFullName: projectFullName ?? undefined,
      worktreePath: undefined,
      isCompleted: false,
      createdAt: now,
      updatedAt: now,
      userId,
      teamId,
    });

    const taskRunId = await ctx.db.insert("taskRuns", {
      taskId,
      prompt: descriptor,
      agentName: DEFAULT_AGENT_NAME,
      status: "pending",
      createdAt: now,
      updatedAt: now,
      userId,
      teamId,
      vscode: {
        provider: "other",
        status: "starting",
        startedAt: now,
      },
    });

    return {
      sequence,
      suffix: workspaceSequenceToName(sequence),
      workspaceName,
      descriptor,
      taskId,
      taskRunId,
    };
  },
});
