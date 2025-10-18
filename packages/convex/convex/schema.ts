import { defineSchema, defineTable } from "convex/server";
import { v } from "convex/values";

const convexSchema = defineSchema({
  teams: defineTable({
    teamId: v.string(),
    // Human-friendly slug used in URLs (internal)
    slug: v.optional(v.string()),
    // Display name from Stack (display_name)
    displayName: v.optional(v.string()),
    // Optional alternate/internal name
    name: v.optional(v.string()),
    // Profile image URL (Stack may send null; omit when null)
    profileImageUrl: v.optional(v.string()),
    // Client metadata blobs from Stack
    clientMetadata: v.optional(v.any()),
    clientReadOnlyMetadata: v.optional(v.any()),
    // Server metadata from Stack
    serverMetadata: v.optional(v.any()),
    // Timestamp from Stack (created_at_millis)
    createdAtMillis: v.optional(v.number()),
    // Local bookkeeping
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_teamId", ["teamId"]) // For fast resolution by teamId
    .index("by_slug", ["slug"]), // For resolving slug -> teamId
  // Stack team membership records
  teamMemberships: defineTable({
    teamId: v.string(), // canonical team UUID
    userId: v.string(),
    role: v.optional(v.union(v.literal("owner"), v.literal("member"))),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_team_user", ["teamId", "userId"]) // check membership quickly
    .index("by_user", ["userId"]) // list teams for a user
    .index("by_team", ["teamId"]),
  // Stack team permission assignments
  teamPermissions: defineTable({
    teamId: v.string(),
    userId: v.string(),
    permissionId: v.string(), // e.g., "$update_team" or "team_member"
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_team_user", ["teamId", "userId"]) // list permissions for a user in team
    .index("by_user", ["userId"]) // all permissions for a user
    .index("by_team", ["teamId"]) // all permissions in a team
    .index("by_team_user_perm", ["teamId", "userId", "permissionId"]),
  // Stack user directory
  users: defineTable({
    userId: v.string(),
    // Basic identity
    primaryEmail: v.optional(v.string()), // nulls omitted
    primaryEmailVerified: v.optional(v.boolean()),
    primaryEmailAuthEnabled: v.optional(v.boolean()),
    displayName: v.optional(v.string()),
    profileImageUrl: v.optional(v.string()),
    // Team selection
    selectedTeamId: v.optional(v.string()),
    selectedTeamDisplayName: v.optional(v.string()),
    selectedTeamProfileImageUrl: v.optional(v.string()),
    // Security flags
    hasPassword: v.optional(v.boolean()),
    otpAuthEnabled: v.optional(v.boolean()),
    passkeyAuthEnabled: v.optional(v.boolean()),
    // Timestamps from Stack
    signedUpAtMillis: v.optional(v.number()),
    lastActiveAtMillis: v.optional(v.number()),
    // Metadata blobs
    clientMetadata: v.optional(v.any()),
    clientReadOnlyMetadata: v.optional(v.any()),
    serverMetadata: v.optional(v.any()),
    // OAuth providers observed in webhook payloads
    oauthProviders: v.optional(
      v.array(
        v.object({
          id: v.string(),
          accountId: v.string(),
          email: v.optional(v.string()),
        })
      )
    ),
    // Anonymous flag
    isAnonymous: v.optional(v.boolean()),
    // Local bookkeeping
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_userId", ["userId"]) // For fast lookup by Stack user id
    .index("by_email", ["primaryEmail"])
    .index("by_selected_team", ["selectedTeamId"]),
  tasks: defineTable({
    text: v.string(),
    isCompleted: v.boolean(),
    isArchived: v.optional(v.boolean()),
    description: v.optional(v.string()),
    pullRequestTitle: v.optional(v.string()),
    pullRequestDescription: v.optional(v.string()),
    projectFullName: v.optional(v.string()),
    baseBranch: v.optional(v.string()),
    worktreePath: v.optional(v.string()),
    generatedBranchName: v.optional(v.string()),
    createdAt: v.optional(v.number()),
    updatedAt: v.optional(v.number()),
    userId: v.string(), // Link to user who created the task
    teamId: v.string(),
    environmentId: v.optional(v.id("environments")),
    crownEvaluationError: v.optional(v.string()), // Error message if crown evaluation failed
    mergeStatus: v.optional(
      v.union(
        v.literal("none"), // No PR activity yet
        v.literal("pr_draft"), // PR created as draft
        v.literal("pr_open"), // PR opened and ready for review
        v.literal("pr_approved"), // PR has been approved
        v.literal("pr_changes_requested"), // PR has changes requested
        v.literal("pr_merged"), // PR has been merged
        v.literal("pr_closed") // PR closed without merging
      )
    ),
    images: v.optional(
      v.array(
        v.object({
          storageId: v.id("_storage"), // Convex storage ID
          fileName: v.optional(v.string()),
          altText: v.string(),
        })
      )
    ),
  })
    .index("by_created", ["createdAt"])
    .index("by_user", ["userId", "createdAt"])
    .index("by_team_user", ["teamId", "userId"]),

  taskRuns: defineTable({
    taskId: v.id("tasks"),
    parentRunId: v.optional(v.id("taskRuns")), // For tree structure
    prompt: v.string(), // The prompt that will be passed to claude
    agentName: v.optional(v.string()), // Name of the agent that ran this task (e.g., "claude/sonnet-4")
    summary: v.optional(v.string()), // Markdown summary of the run
    status: v.union(
      v.literal("pending"),
      v.literal("running"),
      v.literal("completed"),
      v.literal("failed")
    ),
    // Optional log retained for backward compatibility; no longer written to.
    log: v.optional(v.string()), // CLI output log (deprecated)
    worktreePath: v.optional(v.string()), // Path to the git worktree for this run
    newBranch: v.optional(v.string()), // The generated branch name for this run
    createdAt: v.number(),
    updatedAt: v.number(),
    completedAt: v.optional(v.number()),
    exitCode: v.optional(v.number()),
    environmentError: v.optional(
      v.object({
        devError: v.optional(v.string()),
        maintenanceError: v.optional(v.string()),
      }),
    ),
    errorMessage: v.optional(v.string()), // Error message when run fails early
    userId: v.string(), // Link to user who created the run
    teamId: v.string(),
    environmentId: v.optional(v.id("environments")),
    isCrowned: v.optional(v.boolean()), // Whether this run won the crown evaluation
    crownReason: v.optional(v.string()), // LLM's reasoning for why this run was crowned
    pullRequestUrl: v.optional(v.string()), // URL of the PR
    pullRequestIsDraft: v.optional(v.boolean()), // Whether the PR is a draft
    pullRequestState: v.optional(
      v.union(
        v.literal("none"), // no PR exists yet
        v.literal("draft"), // PR exists and is draft
        v.literal("open"), // PR exists and is open/ready for review
        v.literal("merged"), // PR merged
        v.literal("closed"), // PR closed without merge
        v.literal("unknown") // fallback/unsure
      )
    ),
    pullRequestNumber: v.optional(v.number()), // Numeric PR number on provider
    pullRequests: v.optional(
      v.array(
        v.object({
          repoFullName: v.string(),
          url: v.optional(v.string()),
          number: v.optional(v.number()),
          state: v.union(
            v.literal("none"),
            v.literal("draft"),
            v.literal("open"),
            v.literal("merged"),
            v.literal("closed"),
            v.literal("unknown")
          ),
          isDraft: v.optional(v.boolean()),
        })
      )
    ),
    diffsLastUpdated: v.optional(v.number()), // Timestamp when diffs were last fetched/updated
    // VSCode instance information
    vscode: v.optional(
      v.object({
        provider: v.union(
          v.literal("docker"),
          v.literal("morph"),
          v.literal("daytona"),
          v.literal("other")
        ), // Extensible for future providers
        containerName: v.optional(v.string()), // For Docker provider
        status: v.union(
          v.literal("starting"),
          v.literal("running"),
          v.literal("stopped")
        ),
        ports: v.optional(
          v.object({
            vscode: v.string(),
            worker: v.string(),
            extension: v.optional(v.string()),
            proxy: v.optional(v.string()),
            vnc: v.optional(v.string()),
          })
        ),
        url: v.optional(v.string()), // The VSCode URL
        workspaceUrl: v.optional(v.string()), // The workspace URL
        startedAt: v.optional(v.number()),
        stoppedAt: v.optional(v.number()),
        lastAccessedAt: v.optional(v.number()), // Track when user last accessed the container
        keepAlive: v.optional(v.boolean()), // User requested to keep container running
        scheduledStopAt: v.optional(v.number()), // When container is scheduled to stop
      })
    ),
    networking: v.optional(
      v.array(
        v.object({
          status: v.union(
            v.literal("starting"),
            v.literal("running"),
            v.literal("stopped")
          ),
          port: v.number(),
          url: v.string(),
        })
      )
    ),
  })
    .index("by_task", ["taskId", "createdAt"])
    .index("by_parent", ["parentRunId"])
    .index("by_status", ["status"])
    .index("by_vscode_status", ["vscode.status"])
    .index("by_vscode_container_name", ["vscode.containerName"])
    .index("by_user", ["userId", "createdAt"])
    .index("by_team_user", ["teamId", "userId"]),
  taskVersions: defineTable({
    taskId: v.id("tasks"),
    version: v.number(),
    diff: v.string(),
    summary: v.string(),
    createdAt: v.number(),
    userId: v.string(),
    teamId: v.string(),
    files: v.array(
      v.object({
        path: v.string(),
        changes: v.string(),
      })
    ),
  })
    .index("by_task", ["taskId", "version"])
    .index("by_team_user", ["teamId", "userId"]),

  automatedCodeReviewJobs: defineTable({
    teamId: v.optional(v.string()),
    repoFullName: v.string(),
    repoUrl: v.string(),
    prNumber: v.number(),
    commitRef: v.string(),
    requestedByUserId: v.string(),
    state: v.union(
      v.literal("pending"),
      v.literal("running"),
      v.literal("completed"),
      v.literal("failed"),
    ),
    createdAt: v.number(),
    updatedAt: v.number(),
    startedAt: v.optional(v.number()),
    completedAt: v.optional(v.number()),
    sandboxInstanceId: v.optional(v.string()), // `morphvm_` prefix indicates Morph-managed instance IDs
    callbackTokenHash: v.optional(v.string()),
    callbackTokenIssuedAt: v.optional(v.number()),
    errorCode: v.optional(v.string()),
    errorDetail: v.optional(v.string()),
    codeReviewOutput: v.optional(v.record(v.string(), v.any())),
  })
    .index("by_team_repo_pr", ["teamId", "repoFullName", "prNumber", "createdAt"])
    .index("by_team_repo_pr_updated", [
      "teamId",
      "repoFullName",
      "prNumber",
      "updatedAt",
    ])
    .index("by_state_updated", ["state", "updatedAt"])
    .index("by_team_created", ["teamId", "createdAt"]),

  automatedCodeReviewVersions: defineTable({
    jobId: v.id("automatedCodeReviewJobs"),
    teamId: v.optional(v.string()),
    requestedByUserId: v.string(),
    repoFullName: v.string(),
    repoUrl: v.string(),
    prNumber: v.number(),
    commitRef: v.string(),
    sandboxInstanceId: v.optional(v.string()), // `morphvm_` prefix indicates Morph-managed instance IDs
    codeReviewOutput: v.record(v.string(), v.any()),
    createdAt: v.number(),
  })
    .index("by_job", ["jobId"])
    .index("by_team_pr", ["teamId", "repoFullName", "prNumber", "createdAt"]),

  automatedCodeReviewFileOutputs: defineTable({
    jobId: v.id("automatedCodeReviewJobs"),
    teamId: v.optional(v.string()),
    repoFullName: v.string(),
    prNumber: v.number(),
    commitRef: v.string(),
    sandboxInstanceId: v.optional(v.string()),
    filePath: v.string(),
    codexReviewOutput: v.any(),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_job", ["jobId", "createdAt"])
    .index("by_job_file", ["jobId", "filePath"])
    .index("by_team_repo_pr_commit", [
      "teamId",
      "repoFullName",
      "prNumber",
      "commitRef",
      "createdAt",
    ]),

  repos: defineTable({
    fullName: v.string(),
    org: v.string(),
    name: v.string(),
    gitRemote: v.string(),
    provider: v.optional(v.string()), // e.g. "github", "gitlab", etc.
    userId: v.string(),
    teamId: v.string(),
    // Provider metadata (GitHub App)
    providerRepoId: v.optional(v.number()),
    ownerLogin: v.optional(v.string()),
    ownerType: v.optional(
      v.union(v.literal("User"), v.literal("Organization"))
    ),
    visibility: v.optional(v.union(v.literal("public"), v.literal("private"))),
    defaultBranch: v.optional(v.string()),
    connectionId: v.optional(v.id("providerConnections")),
    lastSyncedAt: v.optional(v.number()),
    lastPushedAt: v.optional(v.number()),
  })
    .index("by_org", ["org"])
    .index("by_gitRemote", ["gitRemote"])
    .index("by_team_user", ["teamId", "userId"]) // legacy user scoping
    .index("by_team", ["teamId"]) // team-scoped listing
    .index("by_providerRepoId", ["teamId", "providerRepoId"]) // provider id lookup
    .index("by_connection", ["connectionId"]),
  branches: defineTable({
    repo: v.string(), // legacy string repo name (fullName)
    repoId: v.optional(v.id("repos")), // canonical link to repos table
    name: v.string(),
    userId: v.string(),
    teamId: v.string(),
    lastCommitSha: v.optional(v.string()),
    lastActivityAt: v.optional(v.number()),
    lastKnownBaseSha: v.optional(v.string()),
    lastKnownMergeCommitSha: v.optional(v.string()),
  })
    .index("by_repo", ["repo"])
    .index("by_repoId", ["repoId"]) // new canonical lookup
    .index("by_team_user", ["teamId", "userId"]) // legacy user scoping
    .index("by_team", ["teamId"]),
  taskRunLogChunks: defineTable({
    taskRunId: v.id("taskRuns"),
    content: v.string(), // Log content chunk
    userId: v.string(),
    teamId: v.string(),
  })
    .index("by_taskRun", ["taskRunId"])
    .index("by_team_user", ["teamId", "userId"]),
  apiKeys: defineTable({
    envVar: v.string(), // e.g. "GEMINI_API_KEY"
    value: v.string(), // The actual API key value (encrypted in a real app)
    displayName: v.string(), // e.g. "Gemini API Key"
    description: v.optional(v.string()),
    createdAt: v.number(),
    updatedAt: v.number(),
    userId: v.string(),
    teamId: v.string(),
  })
    .index("by_envVar", ["envVar"])
    .index("by_team_user", ["teamId", "userId"]),
  workspaceSettings: defineTable({
    worktreePath: v.optional(v.string()), // Custom path for git worktrees
    autoPrEnabled: v.optional(v.boolean()), // Auto-create PR for crown winner (default: false)
    createdAt: v.number(),
    updatedAt: v.number(),
    userId: v.string(),
    teamId: v.string(),
  }).index("by_team_user", ["teamId", "userId"]),
  crownEvaluations: defineTable({
    taskId: v.id("tasks"),
    evaluatedAt: v.number(),
    winnerRunId: v.id("taskRuns"),
    candidateRunIds: v.array(v.id("taskRuns")),
    evaluationPrompt: v.string(),
    evaluationResponse: v.string(),
    createdAt: v.number(),
    userId: v.string(),
    teamId: v.string(),
  })
    .index("by_task", ["taskId"])
    .index("by_winner", ["winnerRunId"])
    .index("by_team_user", ["teamId", "userId"]),
  containerSettings: defineTable({
    maxRunningContainers: v.optional(v.number()), // Max containers to keep running (default: 5)
    reviewPeriodMinutes: v.optional(v.number()), // Minutes to keep container after task completion (default: 60)
    autoCleanupEnabled: v.optional(v.boolean()), // Enable automatic cleanup (default: true)
    stopImmediatelyOnCompletion: v.optional(v.boolean()), // Stop containers immediately when tasks complete (default: false)
    minContainersToKeep: v.optional(v.number()), // Minimum containers to always keep alive (default: 0)
    createdAt: v.number(),
    updatedAt: v.number(),
    userId: v.string(),
    teamId: v.string(),
  }).index("by_team_user", ["teamId", "userId"]),

  // System and user comments attached to a task
  taskComments: defineTable({
    taskId: v.id("tasks"),
    content: v.string(),
    userId: v.string(), // "cmux" for system comments; otherwise the author user id
    teamId: v.string(),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_task", ["taskId", "createdAt"]) // fetch comments for a task chronologically
    .index("by_team_task", ["teamId", "taskId", "createdAt"]) // scoped by team
    .index("by_team_user", ["teamId", "userId"]),

  comments: defineTable({
    url: v.string(), // Full URL of the website where comment was created
    page: v.string(), // Page URL/path where comment was created
    pageTitle: v.string(), // Page title for reference
    nodeId: v.string(), // CSS selector path to the element
    x: v.number(), // X position ratio within the element (0-1)
    y: v.number(), // Y position ratio within the element (0-1)
    content: v.string(), // Comment text content
    resolved: v.optional(v.boolean()), // Whether comment is resolved
    archived: v.optional(v.boolean()), // Whether comment is archived
    userId: v.string(), // User who created the comment
    teamId: v.string(),
    profileImageUrl: v.optional(v.string()), // User's profile image URL
    userAgent: v.string(), // Browser user agent
    screenWidth: v.number(), // Screen width when comment was created
    screenHeight: v.number(), // Screen height when comment was created
    devicePixelRatio: v.number(), // Device pixel ratio
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_url", ["url", "createdAt"])
    .index("by_page", ["page", "createdAt"])
    .index("by_user", ["userId", "createdAt"])
    .index("by_resolved", ["resolved", "createdAt"])
    .index("by_team_user", ["teamId", "userId"]),

  commentReplies: defineTable({
    commentId: v.id("comments"),
    userId: v.string(),
    teamId: v.string(),
    content: v.string(),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_comment", ["commentId", "createdAt"])
    .index("by_user", ["userId", "createdAt"])
    .index("by_team_user", ["teamId", "userId"]),

  // GitHub App installation connections (team-scoped, but teamId may be set later)
  providerConnections: defineTable({
    teamId: v.optional(v.string()), // Canonical team UUID; may be set post-install
    connectedByUserId: v.optional(v.string()), // Stack user who linked the install (when known)
    type: v.literal("github_app"),
    installationId: v.number(),
    accountLogin: v.optional(v.string()), // org or user login
    accountId: v.optional(v.number()),
    accountType: v.optional(
      v.union(v.literal("User"), v.literal("Organization"))
    ),
    isActive: v.optional(v.boolean()),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_installationId", ["installationId"]) // resolve installation -> connection
    .index("by_team", ["teamId"]) // list connections for team
    .index("by_team_type", ["teamId", "type"]),

  // Environments for teams
  environments: defineTable({
    name: v.string(), // Human-friendly environment name
    teamId: v.string(), // Team that owns this environment
    userId: v.string(), // User who created the environment
    morphSnapshotId: v.string(), // Morph snapshot identifier
    dataVaultKey: v.string(), // Key for StackAuth DataBook (stores encrypted env vars)
    selectedRepos: v.optional(v.array(v.string())), // List of repository full names
    description: v.optional(v.string()), // Optional description
    maintenanceScript: v.optional(v.string()),
    devScript: v.optional(v.string()),
    exposedPorts: v.optional(v.array(v.number())),
    createdAt: v.number(),
    updatedAt: v.number(),
  })
    .index("by_team", ["teamId", "createdAt"])
    .index("by_team_user", ["teamId", "userId"])
    .index("by_dataVaultKey", ["dataVaultKey"]),

  environmentSnapshotVersions: defineTable({
    environmentId: v.id("environments"),
    teamId: v.string(),
    morphSnapshotId: v.string(),
    version: v.number(),
    createdAt: v.number(),
    createdByUserId: v.string(),
    label: v.optional(v.string()),
    maintenanceScript: v.optional(v.string()),
    devScript: v.optional(v.string()),
  })
    .index("by_environment_version", ["environmentId", "version"])
    .index("by_environment_createdAt", ["environmentId", "createdAt"])
    .index("by_team_createdAt", ["teamId", "createdAt"])
    .index("by_team_snapshot", ["teamId", "morphSnapshotId"]),

  // Webhook deliveries for idempotency and auditing
  webhookDeliveries: defineTable({
    provider: v.string(), // e.g. "github"
    deliveryId: v.string(), // X-GitHub-Delivery
    installationId: v.optional(v.number()),
    payloadHash: v.string(), // sha256 of payload body
    receivedAt: v.number(),
  }).index("by_deliveryId", ["deliveryId"]),

  // Short-lived, single-use install state tokens for mapping installation -> team
  installStates: defineTable({
    nonce: v.string(),
    teamId: v.string(),
    userId: v.string(),
    iat: v.number(),
    exp: v.number(),
    status: v.union(
      v.literal("pending"),
      v.literal("used"),
      v.literal("expired")
    ),
    createdAt: v.number(),
  }).index("by_nonce", ["nonce"]),

  // Pull Requests ingested from GitHub (via webhook or backfill)
  pullRequests: defineTable({
    // Identity within provider and repo context
    provider: v.literal("github"),
    installationId: v.number(),
    repositoryId: v.optional(v.number()),
    repoFullName: v.string(), // owner/repo
    number: v.number(), // PR number
    providerPrId: v.optional(v.number()), // GitHub numeric id

    // Team scoping
    teamId: v.string(),

    // Core fields
    title: v.string(),
    state: v.union(v.literal("open"), v.literal("closed")),
    merged: v.optional(v.boolean()),
    draft: v.optional(v.boolean()),
    authorLogin: v.optional(v.string()),
    authorId: v.optional(v.number()),
    htmlUrl: v.optional(v.string()),

    // Branch and commit info
    baseRef: v.optional(v.string()),
    headRef: v.optional(v.string()),
    baseSha: v.optional(v.string()),
    headSha: v.optional(v.string()),
    mergeCommitSha: v.optional(v.string()),

    // Timestamps
    createdAt: v.optional(v.number()),
    updatedAt: v.optional(v.number()),
    closedAt: v.optional(v.number()),
    mergedAt: v.optional(v.number()),

    // Misc metrics
    commentsCount: v.optional(v.number()),
    reviewCommentsCount: v.optional(v.number()),
    commitsCount: v.optional(v.number()),
    additions: v.optional(v.number()),
    deletions: v.optional(v.number()),
    changedFiles: v.optional(v.number()),
  })
    .index("by_team", ["teamId", "updatedAt"]) // list by team, recent first client-side
    .index("by_team_state", ["teamId", "state", "updatedAt"]) // filter by state
    .index("by_team_repo_number", ["teamId", "repoFullName", "number"]) // upsert key
    .index("by_installation", ["installationId", "updatedAt"]) // debug/ops
    .index("by_repo", ["repoFullName", "updatedAt"]),

  // GitHub Actions workflow runs
  githubWorkflowRuns: defineTable({
    // Identity within provider and repo context
    provider: v.literal("github"),
    installationId: v.number(),
    repositoryId: v.optional(v.number()),
    repoFullName: v.string(), // owner/repo

    // Workflow run identity
    runId: v.number(), // GitHub's run ID
    runNumber: v.number(), // Run number within repo

    // Team scoping
    teamId: v.string(),

    // Workflow info
    workflowId: v.number(),
    workflowName: v.string(),

    // Run details
    name: v.optional(v.string()), // Run name (can be custom)
    event: v.string(), // Event that triggered the run (push, pull_request, etc.)
    status: v.optional(
      v.union(
        v.literal("queued"),
        v.literal("in_progress"),
        v.literal("completed"),
        v.literal("pending"),
        v.literal("waiting")
      )
    ),
    conclusion: v.optional(
      v.union(
        v.literal("success"),
        v.literal("failure"),
        v.literal("neutral"),
        v.literal("cancelled"),
        v.literal("skipped"),
        v.literal("timed_out"),
        v.literal("action_required")
      )
    ),

    // Branch and commit info
    headBranch: v.optional(v.string()),
    headSha: v.optional(v.string()),

    // URLs
    htmlUrl: v.optional(v.string()),

    // Timestamps
    createdAt: v.optional(v.number()),
    updatedAt: v.optional(v.number()),
    runStartedAt: v.optional(v.number()),
    runCompletedAt: v.optional(v.number()),

    // Run times (in seconds)
    runDuration: v.optional(v.number()),

    // Actor info
    actorLogin: v.optional(v.string()),
    actorId: v.optional(v.number()),

    // Triggering PR (if applicable)
    triggeringPrNumber: v.optional(v.number()),
  })
    .index("by_team", ["teamId", "updatedAt"]) // list by team, recent first
    .index("by_team_repo", ["teamId", "repoFullName", "updatedAt"]) // filter by repo
    .index("by_team_workflow", ["teamId", "workflowId", "updatedAt"]) // filter by workflow
    .index("by_installation", ["installationId", "updatedAt"]) // debug/ops
    .index("by_runId", ["runId"]) // unique lookup
    .index("by_repo_runNumber", ["repoFullName", "runNumber"]) // unique per repo
    .index("by_repo_sha", ["repoFullName", "headSha", "runStartedAt"]), // filter by SHA for PR

  // GitHub Check Runs (for Vercel, deployments, etc.)
  githubCheckRuns: defineTable({
    // Identity
    provider: v.literal("github"),
    installationId: v.number(),
    repositoryId: v.optional(v.number()),
    repoFullName: v.string(),
    checkRunId: v.number(), // GitHub check run ID

    // Team scoping
    teamId: v.string(),

    // Check run details
    name: v.string(), // Check name (e.g., "Vercel - cmux-client")
    status: v.optional(
      v.union(
        v.literal("queued"),
        v.literal("in_progress"),
        v.literal("completed"),
        v.literal("pending"),
        v.literal("waiting")
      )
    ),
    conclusion: v.optional(
      v.union(
        v.literal("success"),
        v.literal("failure"),
        v.literal("neutral"),
        v.literal("cancelled"),
        v.literal("skipped"),
        v.literal("timed_out"),
        v.literal("action_required")
      )
    ),

    // Commit info
    headSha: v.string(),

    // URLs
    htmlUrl: v.optional(v.string()),

    // Timestamps
    updatedAt: v.optional(v.number()),
    startedAt: v.optional(v.number()),
    completedAt: v.optional(v.number()),

    // App info (e.g., Vercel)
    appName: v.optional(v.string()),
    appSlug: v.optional(v.string()),

    // Triggering PR (if applicable)
    triggeringPrNumber: v.optional(v.number()),
  })
    .index("by_team", ["teamId", "updatedAt"])
    .index("by_team_repo", ["teamId", "repoFullName", "updatedAt"])
    .index("by_checkRunId", ["checkRunId"])
    .index("by_headSha", ["headSha", "updatedAt"]),

  // GitHub Deployments (Vercel, etc.)
  githubDeployments: defineTable({
    provider: v.literal("github"),
    installationId: v.number(),
    repositoryId: v.optional(v.number()),
    repoFullName: v.string(),
    deploymentId: v.number(),
    teamId: v.string(),

    // Deployment details
    sha: v.string(),
    ref: v.optional(v.string()),
    task: v.optional(v.string()),
    environment: v.optional(v.string()),
    description: v.optional(v.string()),

    // Creator info
    creatorLogin: v.optional(v.string()),

    // Timestamps
    createdAt: v.optional(v.number()),
    updatedAt: v.optional(v.number()),

    // Current status (from latest deployment_status)
    state: v.optional(
      v.union(
        v.literal("error"),
        v.literal("failure"),
        v.literal("pending"),
        v.literal("in_progress"),
        v.literal("queued"),
        v.literal("success")
      )
    ),
    statusDescription: v.optional(v.string()),
    targetUrl: v.optional(v.string()),
    environmentUrl: v.optional(v.string()),
    logUrl: v.optional(v.string()),

    // Triggering PR (if applicable)
    triggeringPrNumber: v.optional(v.number()),
  })
    .index("by_team", ["teamId", "updatedAt"])
    .index("by_team_repo", ["teamId", "repoFullName", "updatedAt"])
    .index("by_deploymentId", ["deploymentId"])
    .index("by_sha", ["sha", "updatedAt"]),

  // GitHub Commit Statuses (legacy status API)
  githubCommitStatuses: defineTable({
    provider: v.literal("github"),
    installationId: v.number(),
    repositoryId: v.optional(v.number()),
    repoFullName: v.string(),
    statusId: v.number(),
    teamId: v.string(),

    // Status details
    sha: v.string(),
    state: v.union(
      v.literal("error"),
      v.literal("failure"),
      v.literal("pending"),
      v.literal("success")
    ),
    context: v.string(),
    description: v.optional(v.string()),
    targetUrl: v.optional(v.string()),

    // Creator info
    creatorLogin: v.optional(v.string()),

    // Timestamps
    createdAt: v.optional(v.number()),
    updatedAt: v.optional(v.number()),

    // Triggering PR (if applicable)
    triggeringPrNumber: v.optional(v.number()),
  })
    .index("by_team", ["teamId", "updatedAt"])
    .index("by_team_repo", ["teamId", "repoFullName", "updatedAt"])
    .index("by_statusId", ["statusId"])
    .index("by_sha_context", ["sha", "context", "updatedAt"])
    .index("by_sha", ["sha", "updatedAt"]),
});

export default convexSchema;
