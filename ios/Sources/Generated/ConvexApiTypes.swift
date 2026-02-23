import ConvexMobile

import Foundation



// Generated from /Users/lawrencechen/fun/cmux/packages/convex/convex/_generated/api.d.ts

// Functions: acp.prewarmSandbox, acp.startConversation, acp.sendMessageOptimistic, acp.sendMessage, acp.retryMessage, acp.sendRpc, acp.cancelConversation, acp.spawnRivetSandbox, acp.getStreamInfo, acp.getConversation, acp.listMessages, acp.subscribeNewMessages, acp.getMessages, acpRawEvents.listByConversationPaginated, acpRawEvents.listByConversationFirstPage, acpSandboxes.listForTeam, acpSandboxes.get, apiKeys.getAll, apiKeys.getByEnvVar, apiKeys.upsert, apiKeys.remove, apiKeys.getAllForAgents, codeReview.reserveJob, codeReview.markJobRunning, codeReview.failJob, codeReview.upsertFileOutputFromCallback, codeReview.completeJobFromCallback, codeReview.failJobFromCallback, codeReview.listFileOutputsForPr, codeReview.listFileOutputsForComparison, codexTokens.get, codexTokens.save, codexTokens.remove, comments.createComment, comments.listComments, comments.resolveComment, comments.archiveComment, comments.addReply, comments.getReplies, containerSettings.get, containerSettings.update, containerSettings.getEffective, conversationMessages.listByConversation, conversationMessages.listByConversationPaginated, conversationMessages.listByConversationFirstPage, conversationReads.markRead, conversationReads.markUnread, conversations.create, conversations.getById, conversations.getDetail, conversations.getBySessionId, conversations.listPagedWithLatest, conversations.listByNamespace, conversations.listBySandbox, conversations.updatePermissionMode, conversations.rename, conversations.pin, conversations.unpin, conversations.archive, conversations.unarchive, conversations.remove, conversations.getFullConversation, crown.evaluateAndCrownWinner, crown.setCrownWinner, crown.getCrownedRun, crown.getCrownEvaluation, crown.getTasksWithCrowns, crown.actions.evaluate, crown.actions.summarize, devboxInstances.list, devboxInstances.getById, devboxInstances.getByProviderInstanceId, devboxInstances.create, devboxInstances.updateStatus, devboxInstances.recordAccess, devboxInstances.remove, e2bInstances.getActivity, e2bInstances.recordResume, environmentSnapshots.list, environmentSnapshots.create, environmentSnapshots.activate, environmentSnapshots.remove, environmentSnapshots.findBySnapshotId, environments.list, environments.get, environments.create, environments.update, environments.updateExposedPorts, environments.remove, environments.getByDataVaultKey, github.getReposByOrg, github.getBranches, github.getRepoByFullName, github.getAllRepos, github.getReposByInstallation, github.getBranchesByRepo, github.hasReposForTeam, github.listProviderConnections, github.listUnassignedProviderConnections, github.assignProviderConnectionToTeam, github.removeProviderConnection, github.upsertRepo, github.bulkInsertRepos, github.bulkInsertBranches, github.bulkUpsertBranchesWithActivity, github.replaceAllRepos, github_app.mintInstallState, github_check_runs.getCheckRunsForPr, github_commit_statuses.getCommitStatusesForPr, github_deployments.getDeploymentsForPr, github_http.addManualRepo, github_prs.listPullRequests, github_prs.getPullRequest, github_prs.upsertFromServer, github_workflows.getWorkflowRuns, github_workflows.getWorkflowRunById, github_workflows.getWorkflowRunsForPr, hostScreenshotCollector.getLatestReleaseUrl, hostScreenshotCollector.listReleases, hostScreenshotCollectorActions.syncRelease, localWorkspaces.nextSequence, localWorkspaces.reserve, morphInstances.getActivity, morphInstances.recordResume, previewConfigs.listByTeam, previewConfigs.get, previewConfigs.getByRepo, previewConfigs.remove, previewConfigs.upsert, previewRuns.listByConfig, previewRuns.listByTeam, previewRuns.listByTeamPaginated, previewRuns.createManual, previewScreenshots.uploadAndComment, previewTestJobs.createTestRun, previewTestJobs.dispatchTestJob, previewTestJobs.listTestRuns, previewTestJobs.getTestRunDetails, previewTestJobs.checkRepoAccess, previewTestJobs.retryTestJob, previewTestJobs.deleteTestRun, pushTokens.upsert, pushTokens.remove, pushTokens.sendTest, stack.upsertUserPublic, stack.deleteUserPublic, stack.upsertTeamPublic, stack.deleteTeamPublic, stack.ensureMembershipPublic, stack.deleteMembershipPublic, stack.ensurePermissionPublic, stack.deletePermissionPublic, storage.generateUploadUrl, storage.getUrl, storage.getUrls, taskComments.listByTask, taskComments.createForTask, taskComments.createSystemForTask, taskComments.latestSystemByTask, taskNotifications.list, taskNotifications.hasUnreadForTask, taskNotifications.getUnreadCount, taskNotifications.getTasksWithUnread, taskNotifications.markTaskRunAsRead, taskNotifications.markTaskRunAsUnread, taskNotifications.markTaskAsRead, taskNotifications.markTaskAsUnread, taskNotifications.markAllAsRead, taskRunLogChunks.appendChunk, taskRunLogChunks.appendChunkPublic, taskRunLogChunks.getChunks, taskRuns.create, taskRuns.getByTask, taskRuns.getRunDiffContext, taskRuns.updateSummary, taskRuns.get, taskRuns.subscribe, taskRuns.updateWorktreePath, taskRuns.updateBranch, taskRuns.updateBranchBatch, taskRuns.getJwt, taskRuns.updateStatusPublic, taskRuns.updateVSCodeInstance, taskRuns.updateVSCodeStatus, taskRuns.updateVSCodePorts, taskRuns.updateVSCodeStatusMessage, taskRuns.getByContainerName, taskRuns.complete, taskRuns.fail, taskRuns.addCustomPreview, taskRuns.removeCustomPreview, taskRuns.updateCustomPreviewUrl, taskRuns.getActiveVSCodeInstances, taskRuns.updateLastAccessed, taskRuns.toggleKeepAlive, taskRuns.updatePullRequestUrl, taskRuns.updatePullRequestState, taskRuns.updateNetworking, taskRuns.updateEnvironmentError, taskRuns.archive, taskRuns.getContainersToStop, taskRuns.getRunningContainersByCleanupPriority, tasks.get, tasks.getArchivedPaginated, tasks.getWithNotificationOrder, tasks.getPreviewTasks, tasks.getPinned, tasks.getTasksWithTaskRuns, tasks.create, tasks.remove, tasks.toggle, tasks.setCompleted, tasks.update, tasks.updateWorktreePath, tasks.getById, tasks.getVersions, tasks.archive, tasks.unarchive, tasks.pin, tasks.unpin, tasks.updateCrownError, tasks.tryBeginCrownEvaluation, tasks.setPullRequestDescription, tasks.setPullRequestTitle, tasks.createVersion, tasks.getTasksWithPendingCrownEvaluation, tasks.updateMergeStatus, tasks.checkAndEvaluateCrown, tasks.getLinkedLocalWorkspace, teams.get, teams.listTeamMemberships, teams.setSlug, teams.setName, userEditorSettings.get, userEditorSettings.upsert, userEditorSettings.clear, users.getCurrentBasic, workspaceConfigs.get, workspaceConfigs.upsert, workspaceSettings.get, workspaceSettings.update



struct ConvexId<Table>: Decodable, Hashable, Sendable, ConvexEncodable {

  let rawValue: String



  init(rawValue: String) {

    self.rawValue = rawValue

  }



  init(from decoder: Decoder) throws {

    let container = try decoder.singleValueContainer()

    rawValue = try container.decode(String.self)

  }



  func convexEncode() throws -> String {

    try rawValue.convexEncode()

  }

}



struct ConvexNull: ConvexEncodable {

  func convexEncode() throws -> String {

    "null"

  }

}



private func convexEncodeArray<T: ConvexEncodable>(_ values: [T]) -> [ConvexEncodable?] {

  values.map { $0 }

}



private func convexEncodeRecord<T: ConvexEncodable>(_ values: [String: T]) -> [String: ConvexEncodable?] {

  var result: [String: ConvexEncodable?] = [:]

  for (key, value) in values {

    result[key] = value

  }

  return result

}



enum ConvexTableAcpRawEvents {}

enum ConvexTableAcpSandboxes {}

enum ConvexTableApiKeys {}

enum ConvexTableAutomatedCodeReviewFileOutputs {}

enum ConvexTableAutomatedCodeReviewJobs {}

enum ConvexTableBranches {}

enum ConvexTableCodexTokens {}

enum ConvexTableCommentReplies {}

enum ConvexTableComments {}

enum ConvexTableContainerSettings {}

enum ConvexTableConversationMessages {}

enum ConvexTableConversations {}

enum ConvexTableCrownEvaluations {}

enum ConvexTableDevboxInstances {}

enum ConvexTableE2bInstanceActivity {}

enum ConvexTableEnvironmentSnapshotVersions {}

enum ConvexTableEnvironments {}

enum ConvexTableGithubCheckRuns {}

enum ConvexTableGithubCommitStatuses {}

enum ConvexTableGithubDeployments {}

enum ConvexTableGithubWorkflowRuns {}

enum ConvexTableHostScreenshotCollectorReleases {}

enum ConvexTableMorphInstanceActivity {}

enum ConvexTablePreviewConfigs {}

enum ConvexTablePreviewRuns {}

enum ConvexTableProviderConnections {}

enum ConvexTablePullRequests {}

enum ConvexTableRepos {}

enum ConvexTableStorage {}

enum ConvexTableTaskComments {}

enum ConvexTableTaskNotifications {}

enum ConvexTableTaskRunLogChunks {}

enum ConvexTableTaskRunScreenshotSets {}

enum ConvexTableTaskRuns {}

enum ConvexTableTaskVersions {}

enum ConvexTableTasks {}

enum ConvexTableTeamMemberships {}

enum ConvexTableTeams {}

enum ConvexTableUserEditorSettings {}

enum ConvexTableWorkspaceConfigs {}

enum ConvexTableWorkspaceSettings {}

enum AcpStartConversationArgsProviderIdEnum: String, Encodable, ConvexEncodable {
    case claude = "claude"
    case codex = "codex"
    case gemini = "gemini"
    case opencode = "opencode"
}

enum AcpStartConversationReturnStatusEnum: String, Decodable {
    case starting = "starting"
    case ready = "ready"
}

enum AcpSendMessageOptimisticArgsProviderIdEnum: String, Encodable, ConvexEncodable {
    case claude = "claude"
    case codex = "codex"
    case gemini = "gemini"
    case opencode = "opencode"
}

enum AcpSendMessageOptimisticArgsContentItemTypeEnum: String, Encodable, ConvexEncodable {
    case text = "text"
    case image = "image"
    case resourceLink = "resource_link"
}

enum AcpSendMessageOptimisticReturnStatusEnum: String, Decodable {
    case error = "error"
    case queued = "queued"
    case sent = "sent"
}

enum AcpSendMessageArgsContentItemTypeEnum: String, Encodable, ConvexEncodable {
    case text = "text"
    case image = "image"
    case resourceLink = "resource_link"
}

enum AcpSendMessageReturnStatusEnum: String, Decodable {
    case error = "error"
    case queued = "queued"
    case sent = "sent"
}

enum AcpRetryMessageReturnStatusEnum: String, Decodable {
    case error = "error"
    case queued = "queued"
    case sent = "sent"
}

enum AcpSendRpcReturnStatusEnum: String, Decodable {
    case error = "error"
    case sent = "sent"
}

enum AcpGetConversationReturnPermissionModeEnum: String, Decodable {
    case manual = "manual"
    case autoAllowOnce = "auto_allow_once"
    case autoAllowAlways = "auto_allow_always"
}

enum AcpGetConversationReturnStopReasonEnum: String, Decodable {
    case cancelled = "cancelled"
    case endTurn = "end_turn"
    case maxTokens = "max_tokens"
    case maxTurnRequests = "max_turn_requests"
    case refusal = "refusal"
}

enum AcpGetConversationReturnIsolationModeEnum: String, Decodable {
    case none = "none"
    case sharedNamespace = "shared_namespace"
    case dedicatedNamespace = "dedicated_namespace"
}

enum AcpGetConversationReturnStatusEnum: String, Decodable {
    case error = "error"
    case completed = "completed"
    case active = "active"
    case cancelled = "cancelled"
}

enum AcpListMessagesReturnMessagesItemDeliveryStatusEnum: String, Decodable {
    case error = "error"
    case queued = "queued"
    case sent = "sent"
}

enum AcpListMessagesReturnMessagesItemToolCallsItemStatusEnum: String, Decodable {
    case pending = "pending"
    case running = "running"
    case completed = "completed"
    case failed = "failed"
}

enum AcpListMessagesReturnMessagesItemRoleEnum: String, Decodable {
    case user = "user"
    case assistant = "assistant"
}

enum AcpListMessagesReturnMessagesItemContentItemTypeEnum: String, Decodable {
    case text = "text"
    case image = "image"
    case audio = "audio"
    case resourceLink = "resource_link"
    case resource = "resource"
}

enum AcpSubscribeNewMessagesItemDeliveryStatusEnum: String, Decodable {
    case error = "error"
    case queued = "queued"
    case sent = "sent"
}

enum AcpSubscribeNewMessagesItemToolCallsItemStatusEnum: String, Decodable {
    case pending = "pending"
    case running = "running"
    case completed = "completed"
    case failed = "failed"
}

enum AcpSubscribeNewMessagesItemRoleEnum: String, Decodable {
    case user = "user"
    case assistant = "assistant"
}

enum AcpSubscribeNewMessagesItemContentItemTypeEnum: String, Decodable {
    case text = "text"
    case image = "image"
    case audio = "audio"
    case resourceLink = "resource_link"
    case resource = "resource"
}

enum AcpGetMessagesItemDeliveryStatusEnum: String, Decodable {
    case error = "error"
    case queued = "queued"
    case sent = "sent"
}

enum AcpGetMessagesItemToolCallsItemStatusEnum: String, Decodable {
    case pending = "pending"
    case running = "running"
    case completed = "completed"
    case failed = "failed"
}

enum AcpGetMessagesItemRoleEnum: String, Decodable {
    case user = "user"
    case assistant = "assistant"
}

enum AcpGetMessagesItemContentItemTypeEnum: String, Decodable {
    case text = "text"
    case image = "image"
    case audio = "audio"
    case resourceLink = "resource_link"
    case resource = "resource"
}

enum AcpRawEventsListByConversationPaginatedReturnPageItemDirectionEnum: String, Decodable {
    case inbound = "inbound"
    case outbound = "outbound"
}

enum AcpRawEventsListByConversationPaginatedReturnPageStatusEnum: String, Decodable {
    case splitRecommended = "SplitRecommended"
    case splitRequired = "SplitRequired"
}

enum AcpRawEventsListByConversationFirstPageReturnPageItemDirectionEnum: String, Decodable {
    case inbound = "inbound"
    case outbound = "outbound"
}

enum AcpRawEventsListByConversationFirstPageReturnPageStatusEnum: String, Decodable {
    case splitRecommended = "SplitRecommended"
    case splitRequired = "SplitRequired"
}

enum AcpSandboxesListForTeamItemPoolStateEnum: String, Decodable {
    case available = "available"
    case reserved = "reserved"
    case claimed = "claimed"
}

enum AcpSandboxesListForTeamItemStatusEnum: String, Decodable {
    case error = "error"
    case running = "running"
    case starting = "starting"
    case stopped = "stopped"
    case paused = "paused"
}

enum AcpSandboxesListForTeamItemProviderEnum: String, Decodable {
    case morph = "morph"
    case daytona = "daytona"
    case freestyle = "freestyle"
    case e2b = "e2b"
    case blaxel = "blaxel"
}

enum AcpSandboxesGetReturnPoolStateEnum: String, Decodable {
    case available = "available"
    case reserved = "reserved"
    case claimed = "claimed"
}

enum AcpSandboxesGetReturnStatusEnum: String, Decodable {
    case error = "error"
    case running = "running"
    case starting = "starting"
    case stopped = "stopped"
    case paused = "paused"
}

enum AcpSandboxesGetReturnProviderEnum: String, Decodable {
    case morph = "morph"
    case daytona = "daytona"
    case freestyle = "freestyle"
    case e2b = "e2b"
    case blaxel = "blaxel"
}

enum CodeReviewReserveJobReturnJobJobTypeEnum: String, Decodable {
    case pullRequest = "pull_request"
    case comparison = "comparison"
}

enum CodeReviewReserveJobReturnJobStateEnum: String, Decodable {
    case pending = "pending"
    case running = "running"
    case completed = "completed"
    case failed = "failed"
}

enum CodeReviewMarkJobRunningReturnJobTypeEnum: String, Decodable {
    case pullRequest = "pull_request"
    case comparison = "comparison"
}

enum CodeReviewMarkJobRunningReturnStateEnum: String, Decodable {
    case pending = "pending"
    case running = "running"
    case completed = "completed"
    case failed = "failed"
}

enum CodeReviewFailJobReturnJobTypeEnum: String, Decodable {
    case pullRequest = "pull_request"
    case comparison = "comparison"
}

enum CodeReviewFailJobReturnStateEnum: String, Decodable {
    case pending = "pending"
    case running = "running"
    case completed = "completed"
    case failed = "failed"
}

enum CodeReviewCompleteJobFromCallbackReturnJobTypeEnum: String, Decodable {
    case pullRequest = "pull_request"
    case comparison = "comparison"
}

enum CodeReviewCompleteJobFromCallbackReturnStateEnum: String, Decodable {
    case pending = "pending"
    case running = "running"
    case completed = "completed"
    case failed = "failed"
}

enum CodeReviewFailJobFromCallbackReturnJobTypeEnum: String, Decodable {
    case pullRequest = "pull_request"
    case comparison = "comparison"
}

enum CodeReviewFailJobFromCallbackReturnStateEnum: String, Decodable {
    case pending = "pending"
    case running = "running"
    case completed = "completed"
    case failed = "failed"
}

enum ConversationMessagesListByConversationReturnMessagesItemDeliveryStatusEnum: String, Decodable {
    case error = "error"
    case queued = "queued"
    case sent = "sent"
}

enum ConversationMessagesListByConversationReturnMessagesItemToolCallsItemStatusEnum: String, Decodable {
    case pending = "pending"
    case running = "running"
    case completed = "completed"
    case failed = "failed"
}

enum ConversationMessagesListByConversationReturnMessagesItemRoleEnum: String, Decodable {
    case user = "user"
    case assistant = "assistant"
}

enum ConversationMessagesListByConversationReturnMessagesItemContentItemTypeEnum: String, Decodable {
    case text = "text"
    case image = "image"
    case audio = "audio"
    case resourceLink = "resource_link"
    case resource = "resource"
}

enum ConversationMessagesListByConversationPaginatedReturnPageItemDeliveryStatusEnum: String, Decodable {
    case error = "error"
    case queued = "queued"
    case sent = "sent"
}

enum ConversationMessagesListByConversationPaginatedReturnPageItemToolCallsItemStatusEnum: String, Decodable {
    case pending = "pending"
    case running = "running"
    case completed = "completed"
    case failed = "failed"
}

enum ConversationMessagesListByConversationPaginatedReturnPageItemRoleEnum: String, Decodable {
    case user = "user"
    case assistant = "assistant"
}

enum ConversationMessagesListByConversationPaginatedReturnPageItemContentItemTypeEnum: String, Decodable {
    case text = "text"
    case image = "image"
    case audio = "audio"
    case resourceLink = "resource_link"
    case resource = "resource"
}

enum ConversationMessagesListByConversationPaginatedReturnPageStatusEnum: String, Decodable {
    case splitRecommended = "SplitRecommended"
    case splitRequired = "SplitRequired"
}

enum ConversationMessagesListByConversationFirstPageReturnPageItemDeliveryStatusEnum: String, Decodable {
    case error = "error"
    case queued = "queued"
    case sent = "sent"
}

enum ConversationMessagesListByConversationFirstPageReturnPageItemToolCallsItemStatusEnum: String, Decodable {
    case pending = "pending"
    case running = "running"
    case completed = "completed"
    case failed = "failed"
}

enum ConversationMessagesListByConversationFirstPageReturnPageItemRoleEnum: String, Decodable {
    case user = "user"
    case assistant = "assistant"
}

enum ConversationMessagesListByConversationFirstPageReturnPageItemContentItemTypeEnum: String, Decodable {
    case text = "text"
    case image = "image"
    case audio = "audio"
    case resourceLink = "resource_link"
    case resource = "resource"
}

enum ConversationMessagesListByConversationFirstPageReturnPageStatusEnum: String, Decodable {
    case splitRecommended = "SplitRecommended"
    case splitRequired = "SplitRequired"
}

enum ConversationsCreateArgsIsolationModeEnum: String, Encodable, ConvexEncodable {
    case none = "none"
    case sharedNamespace = "shared_namespace"
    case dedicatedNamespace = "dedicated_namespace"
}

enum ConversationsCreateArgsProviderIdEnum: String, Encodable, ConvexEncodable {
    case claude = "claude"
    case codex = "codex"
    case gemini = "gemini"
    case opencode = "opencode"
}

enum ConversationsGetByIdReturnPermissionModeEnum: String, Decodable {
    case manual = "manual"
    case autoAllowOnce = "auto_allow_once"
    case autoAllowAlways = "auto_allow_always"
}

enum ConversationsGetByIdReturnStopReasonEnum: String, Decodable {
    case cancelled = "cancelled"
    case endTurn = "end_turn"
    case maxTokens = "max_tokens"
    case maxTurnRequests = "max_turn_requests"
    case refusal = "refusal"
}

enum ConversationsGetByIdReturnIsolationModeEnum: String, Decodable {
    case none = "none"
    case sharedNamespace = "shared_namespace"
    case dedicatedNamespace = "dedicated_namespace"
}

enum ConversationsGetByIdReturnStatusEnum: String, Decodable {
    case error = "error"
    case completed = "completed"
    case active = "active"
    case cancelled = "cancelled"
}

enum ConversationsGetDetailReturnConversationPermissionModeEnum: String, Decodable {
    case manual = "manual"
    case autoAllowOnce = "auto_allow_once"
    case autoAllowAlways = "auto_allow_always"
}

enum ConversationsGetDetailReturnConversationStopReasonEnum: String, Decodable {
    case cancelled = "cancelled"
    case endTurn = "end_turn"
    case maxTokens = "max_tokens"
    case maxTurnRequests = "max_turn_requests"
    case refusal = "refusal"
}

enum ConversationsGetDetailReturnConversationIsolationModeEnum: String, Decodable {
    case none = "none"
    case sharedNamespace = "shared_namespace"
    case dedicatedNamespace = "dedicated_namespace"
}

enum ConversationsGetDetailReturnConversationStatusEnum: String, Decodable {
    case error = "error"
    case completed = "completed"
    case active = "active"
    case cancelled = "cancelled"
}

enum ConversationsGetDetailReturnSandboxStatusEnum: String, Decodable {
    case error = "error"
    case running = "running"
    case starting = "starting"
    case stopped = "stopped"
    case paused = "paused"
}

enum ConversationsGetBySessionIdReturnPermissionModeEnum: String, Decodable {
    case manual = "manual"
    case autoAllowOnce = "auto_allow_once"
    case autoAllowAlways = "auto_allow_always"
}

enum ConversationsGetBySessionIdReturnStopReasonEnum: String, Decodable {
    case cancelled = "cancelled"
    case endTurn = "end_turn"
    case maxTokens = "max_tokens"
    case maxTurnRequests = "max_turn_requests"
    case refusal = "refusal"
}

enum ConversationsGetBySessionIdReturnIsolationModeEnum: String, Decodable {
    case none = "none"
    case sharedNamespace = "shared_namespace"
    case dedicatedNamespace = "dedicated_namespace"
}

enum ConversationsGetBySessionIdReturnStatusEnum: String, Decodable {
    case error = "error"
    case completed = "completed"
    case active = "active"
    case cancelled = "cancelled"
}

enum ConversationsListPagedWithLatestArgsScopeEnum: String, Encodable, ConvexEncodable {
    case mine = "mine"
    case all = "all"
}

enum ConversationsListPagedWithLatestReturnPageItemConversationPermissionModeEnum: String, Decodable {
    case manual = "manual"
    case autoAllowOnce = "auto_allow_once"
    case autoAllowAlways = "auto_allow_always"
}

enum ConversationsListPagedWithLatestReturnPageItemConversationStopReasonEnum: String, Decodable {
    case cancelled = "cancelled"
    case endTurn = "end_turn"
    case maxTokens = "max_tokens"
    case maxTurnRequests = "max_turn_requests"
    case refusal = "refusal"
}

enum ConversationsListPagedWithLatestReturnPageItemConversationIsolationModeEnum: String, Decodable {
    case none = "none"
    case sharedNamespace = "shared_namespace"
    case dedicatedNamespace = "dedicated_namespace"
}

enum ConversationsListPagedWithLatestReturnPageItemConversationStatusEnum: String, Decodable {
    case error = "error"
    case completed = "completed"
    case active = "active"
    case cancelled = "cancelled"
}

enum ConversationsListPagedWithLatestReturnPageItemPreviewKindEnum: String, Decodable {
    case text = "text"
    case image = "image"
    case resource = "resource"
    case empty = "empty"
}

enum ConversationsListPagedWithLatestReturnPageStatusEnum: String, Decodable {
    case splitRecommended = "SplitRecommended"
    case splitRequired = "SplitRequired"
}

enum ConversationsListByNamespaceItemPermissionModeEnum: String, Decodable {
    case manual = "manual"
    case autoAllowOnce = "auto_allow_once"
    case autoAllowAlways = "auto_allow_always"
}

enum ConversationsListByNamespaceItemStopReasonEnum: String, Decodable {
    case cancelled = "cancelled"
    case endTurn = "end_turn"
    case maxTokens = "max_tokens"
    case maxTurnRequests = "max_turn_requests"
    case refusal = "refusal"
}

enum ConversationsListByNamespaceItemIsolationModeEnum: String, Decodable {
    case none = "none"
    case sharedNamespace = "shared_namespace"
    case dedicatedNamespace = "dedicated_namespace"
}

enum ConversationsListByNamespaceItemStatusEnum: String, Decodable {
    case error = "error"
    case completed = "completed"
    case active = "active"
    case cancelled = "cancelled"
}

enum ConversationsListBySandboxItemPermissionModeEnum: String, Decodable {
    case manual = "manual"
    case autoAllowOnce = "auto_allow_once"
    case autoAllowAlways = "auto_allow_always"
}

enum ConversationsListBySandboxItemStopReasonEnum: String, Decodable {
    case cancelled = "cancelled"
    case endTurn = "end_turn"
    case maxTokens = "max_tokens"
    case maxTurnRequests = "max_turn_requests"
    case refusal = "refusal"
}

enum ConversationsListBySandboxItemIsolationModeEnum: String, Decodable {
    case none = "none"
    case sharedNamespace = "shared_namespace"
    case dedicatedNamespace = "dedicated_namespace"
}

enum ConversationsListBySandboxItemStatusEnum: String, Decodable {
    case error = "error"
    case completed = "completed"
    case active = "active"
    case cancelled = "cancelled"
}

enum ConversationsUpdatePermissionModeArgsPermissionModeEnum: String, Encodable, ConvexEncodable {
    case manual = "manual"
    case autoAllowOnce = "auto_allow_once"
    case autoAllowAlways = "auto_allow_always"
}

enum ConversationsGetFullConversationReturnConversationPermissionModeEnum: String, Decodable {
    case manual = "manual"
    case autoAllowOnce = "auto_allow_once"
    case autoAllowAlways = "auto_allow_always"
}

enum ConversationsGetFullConversationReturnConversationStopReasonEnum: String, Decodable {
    case cancelled = "cancelled"
    case endTurn = "end_turn"
    case maxTokens = "max_tokens"
    case maxTurnRequests = "max_turn_requests"
    case refusal = "refusal"
}

enum ConversationsGetFullConversationReturnConversationIsolationModeEnum: String, Decodable {
    case none = "none"
    case sharedNamespace = "shared_namespace"
    case dedicatedNamespace = "dedicated_namespace"
}

enum ConversationsGetFullConversationReturnConversationStatusEnum: String, Decodable {
    case error = "error"
    case completed = "completed"
    case active = "active"
    case cancelled = "cancelled"
}

enum ConversationsGetFullConversationReturnSandboxStatusEnum: String, Decodable {
    case error = "error"
    case running = "running"
    case starting = "starting"
    case stopped = "stopped"
    case paused = "paused"
}

enum ConversationsGetFullConversationReturnMessagesItemDeliveryStatusEnum: String, Decodable {
    case error = "error"
    case queued = "queued"
    case sent = "sent"
}

enum ConversationsGetFullConversationReturnMessagesItemToolCallsItemStatusEnum: String, Decodable {
    case pending = "pending"
    case running = "running"
    case completed = "completed"
    case failed = "failed"
}

enum ConversationsGetFullConversationReturnMessagesItemRoleEnum: String, Decodable {
    case user = "user"
    case assistant = "assistant"
}

enum ConversationsGetFullConversationReturnMessagesItemContentItemTypeEnum: String, Decodable {
    case text = "text"
    case image = "image"
    case audio = "audio"
    case resourceLink = "resource_link"
    case resource = "resource"
}

enum ConversationsGetFullConversationReturnRawEventsItemDirectionEnum: String, Decodable {
    case inbound = "inbound"
    case outbound = "outbound"
}

enum CrownGetCrownedRunReturnPullRequestStateEnum: String, Decodable {
    case none = "none"
    case draft = "draft"
    case `open` = "open"
    case merged = "merged"
    case closed = "closed"
    case unknown = "unknown"
}

enum CrownGetCrownedRunReturnPullRequestsItemStateEnum: String, Decodable {
    case none = "none"
    case draft = "draft"
    case `open` = "open"
    case merged = "merged"
    case closed = "closed"
    case unknown = "unknown"
}

enum CrownGetCrownedRunReturnVscodeStatusEnum: String, Decodable {
    case running = "running"
    case starting = "starting"
    case stopped = "stopped"
}

enum CrownGetCrownedRunReturnVscodeProviderEnum: String, Decodable {
    case docker = "docker"
    case morph = "morph"
    case daytona = "daytona"
    case other = "other"
}

enum CrownGetCrownedRunReturnNetworkingItemStatusEnum: String, Decodable {
    case running = "running"
    case starting = "starting"
    case stopped = "stopped"
}

enum CrownGetCrownedRunReturnStatusEnum: String, Decodable {
    case pending = "pending"
    case running = "running"
    case completed = "completed"
    case failed = "failed"
    case skipped = "skipped"
}

enum DevboxInstancesListArgsProviderEnum: String, Encodable, ConvexEncodable {
    case morph = "morph"
    case e2b = "e2b"
}

enum DevboxInstancesListItemSourceEnum: String, Decodable {
    case cli = "cli"
    case web = "web"
}

enum DevboxInstancesListItemStatusEnum: String, Decodable {
    case running = "running"
    case unknown = "unknown"
    case stopped = "stopped"
    case paused = "paused"
}

enum DevboxInstancesGetByIdReturnSourceEnum: String, Decodable {
    case cli = "cli"
    case web = "web"
}

enum DevboxInstancesGetByIdReturnStatusEnum: String, Decodable {
    case running = "running"
    case unknown = "unknown"
    case stopped = "stopped"
    case paused = "paused"
}

enum DevboxInstancesGetByProviderInstanceIdArgsProviderEnum: String, Encodable, ConvexEncodable {
    case morph = "morph"
    case e2b = "e2b"
}

enum DevboxInstancesGetByProviderInstanceIdReturnProviderEnum: String, Decodable {
    case morph = "morph"
    case e2b = "e2b"
}

enum DevboxInstancesGetByProviderInstanceIdReturnSourceEnum: String, Decodable {
    case cli = "cli"
    case web = "web"
}

enum DevboxInstancesGetByProviderInstanceIdReturnStatusEnum: String, Decodable {
    case running = "running"
    case unknown = "unknown"
    case stopped = "stopped"
    case paused = "paused"
}

enum DevboxInstancesCreateArgsProviderEnum: String, Encodable, ConvexEncodable {
    case morph = "morph"
    case e2b = "e2b"
}

enum DevboxInstancesCreateArgsSourceEnum: String, Encodable, ConvexEncodable {
    case cli = "cli"
    case web = "web"
}

enum DevboxInstancesUpdateStatusArgsProviderEnum: String, Encodable, ConvexEncodable {
    case morph = "morph"
    case e2b = "e2b"
}

enum DevboxInstancesUpdateStatusArgsStatusEnum: String, Encodable, ConvexEncodable {
    case running = "running"
    case unknown = "unknown"
    case stopped = "stopped"
    case paused = "paused"
}

enum DevboxInstancesRecordAccessArgsProviderEnum: String, Encodable, ConvexEncodable {
    case morph = "morph"
    case e2b = "e2b"
}

enum GithubGetReposByOrgReturnValueItemOwnerTypeEnum: String, Decodable {
    case user = "User"
    case organization = "Organization"
}

enum GithubGetReposByOrgReturnValueItemVisibilityEnum: String, Decodable {
    case `public` = "public"
    case `private` = "private"
}

enum GithubGetRepoByFullNameReturnOwnerTypeEnum: String, Decodable {
    case user = "User"
    case organization = "Organization"
}

enum GithubGetRepoByFullNameReturnVisibilityEnum: String, Decodable {
    case `public` = "public"
    case `private` = "private"
}

enum GithubGetAllReposItemOwnerTypeEnum: String, Decodable {
    case user = "User"
    case organization = "Organization"
}

enum GithubGetAllReposItemVisibilityEnum: String, Decodable {
    case `public` = "public"
    case `private` = "private"
}

enum GithubGetReposByInstallationItemOwnerTypeEnum: String, Decodable {
    case user = "User"
    case organization = "Organization"
}

enum GithubGetReposByInstallationItemVisibilityEnum: String, Decodable {
    case `public` = "public"
    case `private` = "private"
}

enum GithubListProviderConnectionsItemAccountTypeEnum: String, Decodable {
    case user = "User"
    case organization = "Organization"
}

enum GithubListUnassignedProviderConnectionsItemAccountTypeEnum: String, Decodable {
    case user = "User"
    case organization = "Organization"
}

enum GithubCheckRunsGetCheckRunsForPrItemStatusEnum: String, Decodable {
    case pending = "pending"
    case inProgress = "in_progress"
    case completed = "completed"
    case queued = "queued"
    case waiting = "waiting"
}

enum GithubCheckRunsGetCheckRunsForPrItemConclusionEnum: String, Decodable {
    case skipped = "skipped"
    case success = "success"
    case failure = "failure"
    case neutral = "neutral"
    case cancelled = "cancelled"
    case timedOut = "timed_out"
    case actionRequired = "action_required"
}

enum GithubCommitStatusesGetCommitStatusesForPrItemStateEnum: String, Decodable {
    case pending = "pending"
    case error = "error"
    case success = "success"
    case failure = "failure"
}

enum GithubDeploymentsGetDeploymentsForPrItemStateEnum: String, Decodable {
    case pending = "pending"
    case inProgress = "in_progress"
    case error = "error"
    case queued = "queued"
    case success = "success"
    case failure = "failure"
}

enum GithubPrsListPullRequestsArgsStateEnum: String, Encodable, ConvexEncodable {
    case `open` = "open"
    case closed = "closed"
    case all = "all"
}

enum GithubPrsListPullRequestsItemStateEnum: String, Decodable {
    case `open` = "open"
    case closed = "closed"
}

enum GithubPrsGetPullRequestReturnStateEnum: String, Decodable {
    case `open` = "open"
    case closed = "closed"
}

enum GithubPrsUpsertFromServerArgsRecordStateEnum: String, Encodable, ConvexEncodable {
    case `open` = "open"
    case closed = "closed"
}

enum GithubWorkflowsGetWorkflowRunsItemStatusEnum: String, Decodable {
    case pending = "pending"
    case inProgress = "in_progress"
    case completed = "completed"
    case queued = "queued"
    case waiting = "waiting"
}

enum GithubWorkflowsGetWorkflowRunsItemConclusionEnum: String, Decodable {
    case skipped = "skipped"
    case success = "success"
    case failure = "failure"
    case neutral = "neutral"
    case cancelled = "cancelled"
    case timedOut = "timed_out"
    case actionRequired = "action_required"
}

enum GithubWorkflowsGetWorkflowRunByIdReturnStatusEnum: String, Decodable {
    case pending = "pending"
    case inProgress = "in_progress"
    case completed = "completed"
    case queued = "queued"
    case waiting = "waiting"
}

enum GithubWorkflowsGetWorkflowRunByIdReturnConclusionEnum: String, Decodable {
    case skipped = "skipped"
    case success = "success"
    case failure = "failure"
    case neutral = "neutral"
    case cancelled = "cancelled"
    case timedOut = "timed_out"
    case actionRequired = "action_required"
}

enum GithubWorkflowsGetWorkflowRunsForPrItemStatusEnum: String, Decodable {
    case pending = "pending"
    case inProgress = "in_progress"
    case completed = "completed"
    case queued = "queued"
    case waiting = "waiting"
}

enum GithubWorkflowsGetWorkflowRunsForPrItemConclusionEnum: String, Decodable {
    case skipped = "skipped"
    case success = "success"
    case failure = "failure"
    case neutral = "neutral"
    case cancelled = "cancelled"
    case timedOut = "timed_out"
    case actionRequired = "action_required"
}

enum PreviewConfigsListByTeamItemStatusEnum: String, Decodable {
    case active = "active"
    case paused = "paused"
    case disabled = "disabled"
}

enum PreviewConfigsGetReturnStatusEnum: String, Decodable {
    case active = "active"
    case paused = "paused"
    case disabled = "disabled"
}

enum PreviewConfigsGetByRepoReturnStatusEnum: String, Decodable {
    case active = "active"
    case paused = "paused"
    case disabled = "disabled"
}

enum PreviewConfigsUpsertArgsStatusEnum: String, Encodable, ConvexEncodable {
    case active = "active"
    case paused = "paused"
    case disabled = "disabled"
}

enum PreviewRunsListByConfigItemStatusEnum: String, Decodable {
    case pending = "pending"
    case running = "running"
    case completed = "completed"
    case failed = "failed"
    case skipped = "skipped"
    case superseded = "superseded"
}

enum PreviewRunsListByTeamItemStatusEnum: String, Decodable {
    case pending = "pending"
    case running = "running"
    case completed = "completed"
    case failed = "failed"
    case skipped = "skipped"
    case superseded = "superseded"
}

enum PreviewRunsListByTeamPaginatedReturnPageItemStatusEnum: String, Decodable {
    case pending = "pending"
    case running = "running"
    case completed = "completed"
    case failed = "failed"
    case skipped = "skipped"
    case superseded = "superseded"
}

enum PreviewRunsListByTeamPaginatedReturnPageStatusEnum: String, Decodable {
    case splitRecommended = "SplitRecommended"
    case splitRequired = "SplitRequired"
}

enum PreviewScreenshotsUploadAndCommentArgsStatusEnum: String, Encodable, ConvexEncodable {
    case completed = "completed"
    case failed = "failed"
    case skipped = "skipped"
}

enum PreviewTestJobsListTestRunsItemStatusEnum: String, Decodable {
    case pending = "pending"
    case running = "running"
    case completed = "completed"
    case failed = "failed"
    case skipped = "skipped"
    case superseded = "superseded"
}

enum PreviewTestJobsListTestRunsItemScreenshotSetStatusEnum: String, Decodable {
    case completed = "completed"
    case failed = "failed"
    case skipped = "skipped"
}

enum PreviewTestJobsGetTestRunDetailsReturnStatusEnum: String, Decodable {
    case pending = "pending"
    case running = "running"
    case completed = "completed"
    case failed = "failed"
    case skipped = "skipped"
    case superseded = "superseded"
}

enum PreviewTestJobsGetTestRunDetailsReturnScreenshotSetStatusEnum: String, Decodable {
    case completed = "completed"
    case failed = "failed"
    case skipped = "skipped"
}

enum PreviewTestJobsCheckRepoAccessReturnErrorCodeEnum: String, Decodable {
    case invalidUrl = "invalid_url"
    case noConfig = "no_config"
    case noInstallation = "no_installation"
    case installationInactive = "installation_inactive"
}

enum PushTokensUpsertArgsEnvironmentEnum: String, Encodable, ConvexEncodable {
    case development = "development"
    case production = "production"
}

enum TaskNotificationsListItemTaskCrownEvaluationStatusEnum: String, Decodable {
    case pending = "pending"
    case inProgress = "in_progress"
    case succeeded = "succeeded"
    case error = "error"
}

enum TaskNotificationsListItemTaskMergeStatusEnum: String, Decodable {
    case none = "none"
    case prDraft = "pr_draft"
    case prOpen = "pr_open"
    case prApproved = "pr_approved"
    case prChangesRequested = "pr_changes_requested"
    case prMerged = "pr_merged"
    case prClosed = "pr_closed"
}

enum TaskNotificationsListItemTaskScreenshotStatusEnum: String, Decodable {
    case pending = "pending"
    case running = "running"
    case completed = "completed"
    case failed = "failed"
    case skipped = "skipped"
}

enum TaskNotificationsListItemTaskRunPullRequestStateEnum: String, Decodable {
    case none = "none"
    case draft = "draft"
    case `open` = "open"
    case merged = "merged"
    case closed = "closed"
    case unknown = "unknown"
}

enum TaskNotificationsListItemTaskRunPullRequestsItemStateEnum: String, Decodable {
    case none = "none"
    case draft = "draft"
    case `open` = "open"
    case merged = "merged"
    case closed = "closed"
    case unknown = "unknown"
}

enum TaskNotificationsListItemTaskRunVscodeStatusEnum: String, Decodable {
    case running = "running"
    case starting = "starting"
    case stopped = "stopped"
}

enum TaskNotificationsListItemTaskRunVscodeProviderEnum: String, Decodable {
    case docker = "docker"
    case morph = "morph"
    case daytona = "daytona"
    case other = "other"
}

enum TaskNotificationsListItemTaskRunNetworkingItemStatusEnum: String, Decodable {
    case running = "running"
    case starting = "starting"
    case stopped = "stopped"
}

enum TaskNotificationsListItemTaskRunStatusEnum: String, Decodable {
    case pending = "pending"
    case running = "running"
    case completed = "completed"
    case failed = "failed"
    case skipped = "skipped"
}

enum TaskNotificationsListItemTypeEnum: String, Decodable {
    case runCompleted = "run_completed"
    case runFailed = "run_failed"
    case runNeedsInput = "run_needs_input"
}

enum TaskRunsGetByTaskItemPullRequestStateEnum: String, Decodable {
    case none = "none"
    case draft = "draft"
    case `open` = "open"
    case merged = "merged"
    case closed = "closed"
    case unknown = "unknown"
}

enum TaskRunsGetByTaskItemPullRequestsItemStateEnum: String, Decodable {
    case none = "none"
    case draft = "draft"
    case `open` = "open"
    case merged = "merged"
    case closed = "closed"
    case unknown = "unknown"
}

enum TaskRunsGetByTaskItemVscodeStatusEnum: String, Decodable {
    case running = "running"
    case starting = "starting"
    case stopped = "stopped"
}

enum TaskRunsGetByTaskItemVscodeProviderEnum: String, Decodable {
    case docker = "docker"
    case morph = "morph"
    case daytona = "daytona"
    case other = "other"
}

enum TaskRunsGetByTaskItemNetworkingItemStatusEnum: String, Decodable {
    case running = "running"
    case starting = "starting"
    case stopped = "stopped"
}

enum TaskRunsGetByTaskItemStatusEnum: String, Decodable {
    case pending = "pending"
    case running = "running"
    case completed = "completed"
    case failed = "failed"
    case skipped = "skipped"
}

enum TaskRunsGetRunDiffContextReturnTaskCrownEvaluationStatusEnum: String, Decodable {
    case pending = "pending"
    case inProgress = "in_progress"
    case succeeded = "succeeded"
    case error = "error"
}

enum TaskRunsGetRunDiffContextReturnTaskMergeStatusEnum: String, Decodable {
    case none = "none"
    case prDraft = "pr_draft"
    case prOpen = "pr_open"
    case prApproved = "pr_approved"
    case prChangesRequested = "pr_changes_requested"
    case prMerged = "pr_merged"
    case prClosed = "pr_closed"
}

enum TaskRunsGetRunDiffContextReturnTaskScreenshotStatusEnum: String, Decodable {
    case pending = "pending"
    case running = "running"
    case completed = "completed"
    case failed = "failed"
    case skipped = "skipped"
}

enum TaskRunsGetRunDiffContextReturnTaskRunsItemPullRequestStateEnum: String, Decodable {
    case none = "none"
    case draft = "draft"
    case `open` = "open"
    case merged = "merged"
    case closed = "closed"
    case unknown = "unknown"
}

enum TaskRunsGetRunDiffContextReturnTaskRunsItemPullRequestsItemStateEnum: String, Decodable {
    case none = "none"
    case draft = "draft"
    case `open` = "open"
    case merged = "merged"
    case closed = "closed"
    case unknown = "unknown"
}

enum TaskRunsGetRunDiffContextReturnTaskRunsItemVscodeStatusEnum: String, Decodable {
    case running = "running"
    case starting = "starting"
    case stopped = "stopped"
}

enum TaskRunsGetRunDiffContextReturnTaskRunsItemVscodeProviderEnum: String, Decodable {
    case docker = "docker"
    case morph = "morph"
    case daytona = "daytona"
    case other = "other"
}

enum TaskRunsGetRunDiffContextReturnTaskRunsItemNetworkingItemStatusEnum: String, Decodable {
    case running = "running"
    case starting = "starting"
    case stopped = "stopped"
}

enum TaskRunsGetRunDiffContextReturnTaskRunsItemStatusEnum: String, Decodable {
    case pending = "pending"
    case running = "running"
    case completed = "completed"
    case failed = "failed"
    case skipped = "skipped"
}

enum TaskRunsGetReturnPullRequestStateEnum: String, Decodable {
    case none = "none"
    case draft = "draft"
    case `open` = "open"
    case merged = "merged"
    case closed = "closed"
    case unknown = "unknown"
}

enum TaskRunsGetReturnPullRequestsItemStateEnum: String, Decodable {
    case none = "none"
    case draft = "draft"
    case `open` = "open"
    case merged = "merged"
    case closed = "closed"
    case unknown = "unknown"
}

enum TaskRunsGetReturnVscodeStatusEnum: String, Decodable {
    case running = "running"
    case starting = "starting"
    case stopped = "stopped"
}

enum TaskRunsGetReturnVscodeProviderEnum: String, Decodable {
    case docker = "docker"
    case morph = "morph"
    case daytona = "daytona"
    case other = "other"
}

enum TaskRunsGetReturnNetworkingItemStatusEnum: String, Decodable {
    case running = "running"
    case starting = "starting"
    case stopped = "stopped"
}

enum TaskRunsGetReturnStatusEnum: String, Decodable {
    case pending = "pending"
    case running = "running"
    case completed = "completed"
    case failed = "failed"
    case skipped = "skipped"
}

enum TaskRunsSubscribeReturnPullRequestStateEnum: String, Decodable {
    case none = "none"
    case draft = "draft"
    case `open` = "open"
    case merged = "merged"
    case closed = "closed"
    case unknown = "unknown"
}

enum TaskRunsSubscribeReturnPullRequestsItemStateEnum: String, Decodable {
    case none = "none"
    case draft = "draft"
    case `open` = "open"
    case merged = "merged"
    case closed = "closed"
    case unknown = "unknown"
}

enum TaskRunsSubscribeReturnVscodeStatusEnum: String, Decodable {
    case running = "running"
    case starting = "starting"
    case stopped = "stopped"
}

enum TaskRunsSubscribeReturnVscodeProviderEnum: String, Decodable {
    case docker = "docker"
    case morph = "morph"
    case daytona = "daytona"
    case other = "other"
}

enum TaskRunsSubscribeReturnNetworkingItemStatusEnum: String, Decodable {
    case running = "running"
    case starting = "starting"
    case stopped = "stopped"
}

enum TaskRunsSubscribeReturnStatusEnum: String, Decodable {
    case pending = "pending"
    case running = "running"
    case completed = "completed"
    case failed = "failed"
    case skipped = "skipped"
}

enum TaskRunsUpdateStatusPublicArgsStatusEnum: String, Encodable, ConvexEncodable {
    case pending = "pending"
    case running = "running"
    case completed = "completed"
    case failed = "failed"
}

enum TaskRunsUpdateVSCodeInstanceArgsVscodeStatusEnum: String, Encodable, ConvexEncodable {
    case running = "running"
    case starting = "starting"
    case stopped = "stopped"
}

enum TaskRunsUpdateVSCodeInstanceArgsVscodeProviderEnum: String, Encodable, ConvexEncodable {
    case docker = "docker"
    case morph = "morph"
    case daytona = "daytona"
    case other = "other"
}

enum TaskRunsUpdateVSCodeStatusArgsStatusEnum: String, Encodable, ConvexEncodable {
    case running = "running"
    case starting = "starting"
    case stopped = "stopped"
}

enum TaskRunsGetByContainerNameReturnPullRequestStateEnum: String, Decodable {
    case none = "none"
    case draft = "draft"
    case `open` = "open"
    case merged = "merged"
    case closed = "closed"
    case unknown = "unknown"
}

enum TaskRunsGetByContainerNameReturnPullRequestsItemStateEnum: String, Decodable {
    case none = "none"
    case draft = "draft"
    case `open` = "open"
    case merged = "merged"
    case closed = "closed"
    case unknown = "unknown"
}

enum TaskRunsGetByContainerNameReturnVscodeStatusEnum: String, Decodable {
    case running = "running"
    case starting = "starting"
    case stopped = "stopped"
}

enum TaskRunsGetByContainerNameReturnVscodeProviderEnum: String, Decodable {
    case docker = "docker"
    case morph = "morph"
    case daytona = "daytona"
    case other = "other"
}

enum TaskRunsGetByContainerNameReturnNetworkingItemStatusEnum: String, Decodable {
    case running = "running"
    case starting = "starting"
    case stopped = "stopped"
}

enum TaskRunsGetByContainerNameReturnStatusEnum: String, Decodable {
    case pending = "pending"
    case running = "running"
    case completed = "completed"
    case failed = "failed"
    case skipped = "skipped"
}

enum TaskRunsGetActiveVSCodeInstancesItemPullRequestStateEnum: String, Decodable {
    case none = "none"
    case draft = "draft"
    case `open` = "open"
    case merged = "merged"
    case closed = "closed"
    case unknown = "unknown"
}

enum TaskRunsGetActiveVSCodeInstancesItemPullRequestsItemStateEnum: String, Decodable {
    case none = "none"
    case draft = "draft"
    case `open` = "open"
    case merged = "merged"
    case closed = "closed"
    case unknown = "unknown"
}

enum TaskRunsGetActiveVSCodeInstancesItemVscodeStatusEnum: String, Decodable {
    case running = "running"
    case starting = "starting"
    case stopped = "stopped"
}

enum TaskRunsGetActiveVSCodeInstancesItemVscodeProviderEnum: String, Decodable {
    case docker = "docker"
    case morph = "morph"
    case daytona = "daytona"
    case other = "other"
}

enum TaskRunsGetActiveVSCodeInstancesItemNetworkingItemStatusEnum: String, Decodable {
    case running = "running"
    case starting = "starting"
    case stopped = "stopped"
}

enum TaskRunsGetActiveVSCodeInstancesItemStatusEnum: String, Decodable {
    case pending = "pending"
    case running = "running"
    case completed = "completed"
    case failed = "failed"
    case skipped = "skipped"
}

enum TaskRunsUpdatePullRequestUrlArgsPullRequestsItemStateEnum: String, Encodable, ConvexEncodable {
    case none = "none"
    case draft = "draft"
    case `open` = "open"
    case merged = "merged"
    case closed = "closed"
    case unknown = "unknown"
}

enum TaskRunsUpdatePullRequestUrlArgsStateEnum: String, Encodable, ConvexEncodable {
    case none = "none"
    case draft = "draft"
    case `open` = "open"
    case merged = "merged"
    case closed = "closed"
    case unknown = "unknown"
}

enum TaskRunsUpdatePullRequestStateArgsPullRequestsItemStateEnum: String, Encodable, ConvexEncodable {
    case none = "none"
    case draft = "draft"
    case `open` = "open"
    case merged = "merged"
    case closed = "closed"
    case unknown = "unknown"
}

enum TaskRunsUpdatePullRequestStateArgsStateEnum: String, Encodable, ConvexEncodable {
    case none = "none"
    case draft = "draft"
    case `open` = "open"
    case merged = "merged"
    case closed = "closed"
    case unknown = "unknown"
}

enum TaskRunsUpdateNetworkingArgsNetworkingItemStatusEnum: String, Encodable, ConvexEncodable {
    case running = "running"
    case starting = "starting"
    case stopped = "stopped"
}

enum TaskRunsGetContainersToStopItemPullRequestStateEnum: String, Decodable {
    case none = "none"
    case draft = "draft"
    case `open` = "open"
    case merged = "merged"
    case closed = "closed"
    case unknown = "unknown"
}

enum TaskRunsGetContainersToStopItemPullRequestsItemStateEnum: String, Decodable {
    case none = "none"
    case draft = "draft"
    case `open` = "open"
    case merged = "merged"
    case closed = "closed"
    case unknown = "unknown"
}

enum TaskRunsGetContainersToStopItemVscodeStatusEnum: String, Decodable {
    case running = "running"
    case starting = "starting"
    case stopped = "stopped"
}

enum TaskRunsGetContainersToStopItemVscodeProviderEnum: String, Decodable {
    case docker = "docker"
    case morph = "morph"
    case daytona = "daytona"
    case other = "other"
}

enum TaskRunsGetContainersToStopItemNetworkingItemStatusEnum: String, Decodable {
    case running = "running"
    case starting = "starting"
    case stopped = "stopped"
}

enum TaskRunsGetContainersToStopItemStatusEnum: String, Decodable {
    case pending = "pending"
    case running = "running"
    case completed = "completed"
    case failed = "failed"
    case skipped = "skipped"
}

enum TaskRunsGetRunningContainersByCleanupPriorityReturnReviewContainersItemPullRequestStateEnum: String, Decodable {
    case none = "none"
    case draft = "draft"
    case `open` = "open"
    case merged = "merged"
    case closed = "closed"
    case unknown = "unknown"
}

enum TaskRunsGetRunningContainersByCleanupPriorityReturnReviewContainersItemPullRequestsItemStateEnum: String, Decodable {
    case none = "none"
    case draft = "draft"
    case `open` = "open"
    case merged = "merged"
    case closed = "closed"
    case unknown = "unknown"
}

enum TaskRunsGetRunningContainersByCleanupPriorityReturnReviewContainersItemVscodeStatusEnum: String, Decodable {
    case running = "running"
    case starting = "starting"
    case stopped = "stopped"
}

enum TaskRunsGetRunningContainersByCleanupPriorityReturnReviewContainersItemVscodeProviderEnum: String, Decodable {
    case docker = "docker"
    case morph = "morph"
    case daytona = "daytona"
    case other = "other"
}

enum TaskRunsGetRunningContainersByCleanupPriorityReturnReviewContainersItemNetworkingItemStatusEnum: String, Decodable {
    case running = "running"
    case starting = "starting"
    case stopped = "stopped"
}

enum TaskRunsGetRunningContainersByCleanupPriorityReturnReviewContainersItemStatusEnum: String, Decodable {
    case pending = "pending"
    case running = "running"
    case completed = "completed"
    case failed = "failed"
    case skipped = "skipped"
}

enum TaskRunsGetRunningContainersByCleanupPriorityReturnActiveContainersItemPullRequestStateEnum: String, Decodable {
    case none = "none"
    case draft = "draft"
    case `open` = "open"
    case merged = "merged"
    case closed = "closed"
    case unknown = "unknown"
}

enum TaskRunsGetRunningContainersByCleanupPriorityReturnActiveContainersItemPullRequestsItemStateEnum: String, Decodable {
    case none = "none"
    case draft = "draft"
    case `open` = "open"
    case merged = "merged"
    case closed = "closed"
    case unknown = "unknown"
}

enum TaskRunsGetRunningContainersByCleanupPriorityReturnActiveContainersItemVscodeStatusEnum: String, Decodable {
    case running = "running"
    case starting = "starting"
    case stopped = "stopped"
}

enum TaskRunsGetRunningContainersByCleanupPriorityReturnActiveContainersItemVscodeProviderEnum: String, Decodable {
    case docker = "docker"
    case morph = "morph"
    case daytona = "daytona"
    case other = "other"
}

enum TaskRunsGetRunningContainersByCleanupPriorityReturnActiveContainersItemNetworkingItemStatusEnum: String, Decodable {
    case running = "running"
    case starting = "starting"
    case stopped = "stopped"
}

enum TaskRunsGetRunningContainersByCleanupPriorityReturnActiveContainersItemStatusEnum: String, Decodable {
    case pending = "pending"
    case running = "running"
    case completed = "completed"
    case failed = "failed"
    case skipped = "skipped"
}

enum TaskRunsGetRunningContainersByCleanupPriorityReturnPrioritizedForCleanupItemPullRequestStateEnum: String, Decodable {
    case none = "none"
    case draft = "draft"
    case `open` = "open"
    case merged = "merged"
    case closed = "closed"
    case unknown = "unknown"
}

enum TaskRunsGetRunningContainersByCleanupPriorityReturnPrioritizedForCleanupItemPullRequestsItemStateEnum: String, Decodable {
    case none = "none"
    case draft = "draft"
    case `open` = "open"
    case merged = "merged"
    case closed = "closed"
    case unknown = "unknown"
}

enum TaskRunsGetRunningContainersByCleanupPriorityReturnPrioritizedForCleanupItemVscodeStatusEnum: String, Decodable {
    case running = "running"
    case starting = "starting"
    case stopped = "stopped"
}

enum TaskRunsGetRunningContainersByCleanupPriorityReturnPrioritizedForCleanupItemVscodeProviderEnum: String, Decodable {
    case docker = "docker"
    case morph = "morph"
    case daytona = "daytona"
    case other = "other"
}

enum TaskRunsGetRunningContainersByCleanupPriorityReturnPrioritizedForCleanupItemNetworkingItemStatusEnum: String, Decodable {
    case running = "running"
    case starting = "starting"
    case stopped = "stopped"
}

enum TaskRunsGetRunningContainersByCleanupPriorityReturnPrioritizedForCleanupItemStatusEnum: String, Decodable {
    case pending = "pending"
    case running = "running"
    case completed = "completed"
    case failed = "failed"
    case skipped = "skipped"
}

enum TasksGetItemCrownEvaluationStatusEnum: String, Decodable {
    case pending = "pending"
    case inProgress = "in_progress"
    case succeeded = "succeeded"
    case error = "error"
}

enum TasksGetItemMergeStatusEnum: String, Decodable {
    case none = "none"
    case prDraft = "pr_draft"
    case prOpen = "pr_open"
    case prApproved = "pr_approved"
    case prChangesRequested = "pr_changes_requested"
    case prMerged = "pr_merged"
    case prClosed = "pr_closed"
}

enum TasksGetItemScreenshotStatusEnum: String, Decodable {
    case pending = "pending"
    case running = "running"
    case completed = "completed"
    case failed = "failed"
    case skipped = "skipped"
}

enum TasksGetArchivedPaginatedReturnPageItemCrownEvaluationStatusEnum: String, Decodable {
    case pending = "pending"
    case inProgress = "in_progress"
    case succeeded = "succeeded"
    case error = "error"
}

enum TasksGetArchivedPaginatedReturnPageItemMergeStatusEnum: String, Decodable {
    case none = "none"
    case prDraft = "pr_draft"
    case prOpen = "pr_open"
    case prApproved = "pr_approved"
    case prChangesRequested = "pr_changes_requested"
    case prMerged = "pr_merged"
    case prClosed = "pr_closed"
}

enum TasksGetArchivedPaginatedReturnPageItemScreenshotStatusEnum: String, Decodable {
    case pending = "pending"
    case running = "running"
    case completed = "completed"
    case failed = "failed"
    case skipped = "skipped"
}

enum TasksGetArchivedPaginatedReturnPageStatusEnum: String, Decodable {
    case splitRecommended = "SplitRecommended"
    case splitRequired = "SplitRequired"
}

enum TasksGetWithNotificationOrderItemCrownEvaluationStatusEnum: String, Decodable {
    case pending = "pending"
    case inProgress = "in_progress"
    case succeeded = "succeeded"
    case error = "error"
}

enum TasksGetWithNotificationOrderItemMergeStatusEnum: String, Decodable {
    case none = "none"
    case prDraft = "pr_draft"
    case prOpen = "pr_open"
    case prApproved = "pr_approved"
    case prChangesRequested = "pr_changes_requested"
    case prMerged = "pr_merged"
    case prClosed = "pr_closed"
}

enum TasksGetWithNotificationOrderItemScreenshotStatusEnum: String, Decodable {
    case pending = "pending"
    case running = "running"
    case completed = "completed"
    case failed = "failed"
    case skipped = "skipped"
}

enum TasksGetPreviewTasksItemCrownEvaluationStatusEnum: String, Decodable {
    case pending = "pending"
    case inProgress = "in_progress"
    case succeeded = "succeeded"
    case error = "error"
}

enum TasksGetPreviewTasksItemMergeStatusEnum: String, Decodable {
    case none = "none"
    case prDraft = "pr_draft"
    case prOpen = "pr_open"
    case prApproved = "pr_approved"
    case prChangesRequested = "pr_changes_requested"
    case prMerged = "pr_merged"
    case prClosed = "pr_closed"
}

enum TasksGetPreviewTasksItemScreenshotStatusEnum: String, Decodable {
    case pending = "pending"
    case running = "running"
    case completed = "completed"
    case failed = "failed"
    case skipped = "skipped"
}

enum TasksGetPinnedItemCrownEvaluationStatusEnum: String, Decodable {
    case pending = "pending"
    case inProgress = "in_progress"
    case succeeded = "succeeded"
    case error = "error"
}

enum TasksGetPinnedItemMergeStatusEnum: String, Decodable {
    case none = "none"
    case prDraft = "pr_draft"
    case prOpen = "pr_open"
    case prApproved = "pr_approved"
    case prChangesRequested = "pr_changes_requested"
    case prMerged = "pr_merged"
    case prClosed = "pr_closed"
}

enum TasksGetPinnedItemScreenshotStatusEnum: String, Decodable {
    case pending = "pending"
    case running = "running"
    case completed = "completed"
    case failed = "failed"
    case skipped = "skipped"
}

enum TasksGetTasksWithTaskRunsItemSelectedTaskRunPullRequestStateEnum: String, Decodable {
    case none = "none"
    case draft = "draft"
    case `open` = "open"
    case merged = "merged"
    case closed = "closed"
    case unknown = "unknown"
}

enum TasksGetTasksWithTaskRunsItemSelectedTaskRunPullRequestsItemStateEnum: String, Decodable {
    case none = "none"
    case draft = "draft"
    case `open` = "open"
    case merged = "merged"
    case closed = "closed"
    case unknown = "unknown"
}

enum TasksGetTasksWithTaskRunsItemSelectedTaskRunVscodeStatusEnum: String, Decodable {
    case running = "running"
    case starting = "starting"
    case stopped = "stopped"
}

enum TasksGetTasksWithTaskRunsItemSelectedTaskRunVscodeProviderEnum: String, Decodable {
    case docker = "docker"
    case morph = "morph"
    case daytona = "daytona"
    case other = "other"
}

enum TasksGetTasksWithTaskRunsItemSelectedTaskRunNetworkingItemStatusEnum: String, Decodable {
    case running = "running"
    case starting = "starting"
    case stopped = "stopped"
}

enum TasksGetTasksWithTaskRunsItemSelectedTaskRunStatusEnum: String, Decodable {
    case pending = "pending"
    case running = "running"
    case completed = "completed"
    case failed = "failed"
    case skipped = "skipped"
}

enum TasksGetTasksWithTaskRunsItemCrownEvaluationStatusEnum: String, Decodable {
    case pending = "pending"
    case inProgress = "in_progress"
    case succeeded = "succeeded"
    case error = "error"
}

enum TasksGetTasksWithTaskRunsItemMergeStatusEnum: String, Decodable {
    case none = "none"
    case prDraft = "pr_draft"
    case prOpen = "pr_open"
    case prApproved = "pr_approved"
    case prChangesRequested = "pr_changes_requested"
    case prMerged = "pr_merged"
    case prClosed = "pr_closed"
}

enum TasksGetTasksWithTaskRunsItemScreenshotStatusEnum: String, Decodable {
    case pending = "pending"
    case running = "running"
    case completed = "completed"
    case failed = "failed"
    case skipped = "skipped"
}

enum TasksGetByIdReturnCrownEvaluationStatusEnum: String, Decodable {
    case pending = "pending"
    case inProgress = "in_progress"
    case succeeded = "succeeded"
    case error = "error"
}

enum TasksGetByIdReturnMergeStatusEnum: String, Decodable {
    case none = "none"
    case prDraft = "pr_draft"
    case prOpen = "pr_open"
    case prApproved = "pr_approved"
    case prChangesRequested = "pr_changes_requested"
    case prMerged = "pr_merged"
    case prClosed = "pr_closed"
}

enum TasksGetByIdReturnScreenshotStatusEnum: String, Decodable {
    case pending = "pending"
    case running = "running"
    case completed = "completed"
    case failed = "failed"
    case skipped = "skipped"
}

enum TasksUpdateCrownErrorArgsCrownEvaluationStatusEnum: String, Encodable, ConvexEncodable {
    case pending = "pending"
    case inProgress = "in_progress"
    case succeeded = "succeeded"
    case error = "error"
}

enum TasksGetTasksWithPendingCrownEvaluationItemCrownEvaluationStatusEnum: String, Decodable {
    case pending = "pending"
    case inProgress = "in_progress"
    case succeeded = "succeeded"
    case error = "error"
}

enum TasksGetTasksWithPendingCrownEvaluationItemMergeStatusEnum: String, Decodable {
    case none = "none"
    case prDraft = "pr_draft"
    case prOpen = "pr_open"
    case prApproved = "pr_approved"
    case prChangesRequested = "pr_changes_requested"
    case prMerged = "pr_merged"
    case prClosed = "pr_closed"
}

enum TasksGetTasksWithPendingCrownEvaluationItemScreenshotStatusEnum: String, Decodable {
    case pending = "pending"
    case running = "running"
    case completed = "completed"
    case failed = "failed"
    case skipped = "skipped"
}

enum TasksUpdateMergeStatusArgsMergeStatusEnum: String, Encodable, ConvexEncodable {
    case none = "none"
    case prDraft = "pr_draft"
    case prOpen = "pr_open"
    case prApproved = "pr_approved"
    case prChangesRequested = "pr_changes_requested"
    case prMerged = "pr_merged"
    case prClosed = "pr_closed"
}

enum TasksGetLinkedLocalWorkspaceReturnTaskCrownEvaluationStatusEnum: String, Decodable {
    case pending = "pending"
    case inProgress = "in_progress"
    case succeeded = "succeeded"
    case error = "error"
}

enum TasksGetLinkedLocalWorkspaceReturnTaskMergeStatusEnum: String, Decodable {
    case none = "none"
    case prDraft = "pr_draft"
    case prOpen = "pr_open"
    case prApproved = "pr_approved"
    case prChangesRequested = "pr_changes_requested"
    case prMerged = "pr_merged"
    case prClosed = "pr_closed"
}

enum TasksGetLinkedLocalWorkspaceReturnTaskScreenshotStatusEnum: String, Decodable {
    case pending = "pending"
    case running = "running"
    case completed = "completed"
    case failed = "failed"
    case skipped = "skipped"
}

enum TasksGetLinkedLocalWorkspaceReturnTaskRunPullRequestStateEnum: String, Decodable {
    case none = "none"
    case draft = "draft"
    case `open` = "open"
    case merged = "merged"
    case closed = "closed"
    case unknown = "unknown"
}

enum TasksGetLinkedLocalWorkspaceReturnTaskRunPullRequestsItemStateEnum: String, Decodable {
    case none = "none"
    case draft = "draft"
    case `open` = "open"
    case merged = "merged"
    case closed = "closed"
    case unknown = "unknown"
}

enum TasksGetLinkedLocalWorkspaceReturnTaskRunVscodeStatusEnum: String, Decodable {
    case running = "running"
    case starting = "starting"
    case stopped = "stopped"
}

enum TasksGetLinkedLocalWorkspaceReturnTaskRunVscodeProviderEnum: String, Decodable {
    case docker = "docker"
    case morph = "morph"
    case daytona = "daytona"
    case other = "other"
}

enum TasksGetLinkedLocalWorkspaceReturnTaskRunNetworkingItemStatusEnum: String, Decodable {
    case running = "running"
    case starting = "starting"
    case stopped = "stopped"
}

enum TasksGetLinkedLocalWorkspaceReturnTaskRunStatusEnum: String, Decodable {
    case pending = "pending"
    case running = "running"
    case completed = "completed"
    case failed = "failed"
    case skipped = "skipped"
}

enum TeamsListTeamMembershipsItemRoleEnum: String, Decodable {
    case owner = "owner"
    case member = "member"
}

enum WorkspaceSettingsGetReturnConversationTitleStyleEnum: String, Decodable {
    case sentence = "sentence"
    case lowercase = "lowercase"
    case title = "title"
}

enum WorkspaceSettingsGetReturnAcpSandboxProviderEnum: String, Decodable {
    case morph = "morph"
    case daytona = "daytona"
    case freestyle = "freestyle"
    case e2b = "e2b"
    case blaxel = "blaxel"
}

enum WorkspaceSettingsGetReturnMcpServersItemTransportEnum: String, Decodable {
    case http = "http"
    case stdio = "stdio"
    case sse = "sse"
}

enum WorkspaceSettingsUpdateArgsConversationTitleStyleEnum: String, Encodable, ConvexEncodable {
    case sentence = "sentence"
    case lowercase = "lowercase"
    case title = "title"
}

enum WorkspaceSettingsUpdateArgsAcpSandboxProviderEnum: String, Encodable, ConvexEncodable {
    case morph = "morph"
    case daytona = "daytona"
    case freestyle = "freestyle"
    case e2b = "e2b"
    case blaxel = "blaxel"
}

enum WorkspaceSettingsUpdateArgsMcpServersItemTransportEnum: String, Encodable, ConvexEncodable {
    case http = "http"
    case stdio = "stdio"
    case sse = "sse"
}

struct AcpPrewarmSandboxReturn: Decodable {
    let sandboxId: ConvexId<ConvexTableAcpSandboxes>
}

struct AcpStartConversationReturn: Decodable {
    let conversationId: ConvexId<ConvexTableConversations>
    let sandboxId: ConvexId<ConvexTableAcpSandboxes>
    let status: AcpStartConversationReturnStatusEnum
}

struct AcpSendMessageOptimisticArgsContentItem: ConvexEncodable {
    let name: String?
    let text: String?
    let mimeType: String?
    let data: String?
    let uri: String?
    let type: AcpSendMessageOptimisticArgsContentItemTypeEnum

    func convexEncode() throws -> String {
        var result: [String: ConvexEncodable?] = [:]
        if let value = name { result["name"] = value }
        if let value = text { result["text"] = value }
        if let value = mimeType { result["mimeType"] = value }
        if let value = data { result["data"] = value }
        if let value = uri { result["uri"] = value }
        result["type"] = type
        return try result.convexEncode()
    }
}

struct AcpSendMessageOptimisticReturn: Decodable {
    let conversationId: ConvexId<ConvexTableConversations>
    let messageId: ConvexId<ConvexTableConversationMessages>
    let status: AcpSendMessageOptimisticReturnStatusEnum
    let error: String?
}

struct AcpSendMessageArgsContentItem: ConvexEncodable {
    let name: String?
    let text: String?
    let mimeType: String?
    let data: String?
    let uri: String?
    let type: AcpSendMessageArgsContentItemTypeEnum

    func convexEncode() throws -> String {
        var result: [String: ConvexEncodable?] = [:]
        if let value = name { result["name"] = value }
        if let value = text { result["text"] = value }
        if let value = mimeType { result["mimeType"] = value }
        if let value = data { result["data"] = value }
        if let value = uri { result["uri"] = value }
        result["type"] = type
        return try result.convexEncode()
    }
}

struct AcpSendMessageReturn: Decodable {
    let messageId: ConvexId<ConvexTableConversationMessages>
    let status: AcpSendMessageReturnStatusEnum
    let error: String?
}

struct AcpRetryMessageReturn: Decodable {
    let status: AcpRetryMessageReturnStatusEnum
    let error: String?
}

struct AcpSendRpcReturn: Decodable {
    let status: AcpSendRpcReturnStatusEnum
    let error: String?
}

struct AcpCancelConversationReturn: Decodable {
    let success: Bool
}

struct AcpSpawnRivetSandboxReturn: Decodable {
    let sandboxId: String
    let sandboxUrl: String
}

struct AcpGetStreamInfoReturn: Decodable {
    let sandboxUrl: String?
    let token: String?
    let status: String
}

struct AcpGetConversationReturnModesAvailableModesItem: Decodable {
    let description: String?
    let id: String
    let name: String
}

struct AcpGetConversationReturnModes: Decodable {
    let currentModeId: String
    let availableModes: [AcpGetConversationReturnModesAvailableModesItem]
}

struct AcpGetConversationReturnAgentInfo: Decodable {
    let title: String?
    let name: String
    let version: String
}

struct AcpGetConversationReturn: Decodable {
    let _id: ConvexId<ConvexTableConversations>
    @ConvexFloat var _creationTime: Double
    let userId: String?
    let isArchived: Bool?
    let pinned: Bool?
    let sandboxInstanceId: String?
    let title: String?
    let clientConversationId: String?
    let modelId: String?
    let permissionMode: AcpGetConversationReturnPermissionModeEnum?
    let stopReason: AcpGetConversationReturnStopReasonEnum?
    let namespaceId: String?
    let isolationMode: AcpGetConversationReturnIsolationModeEnum?
    let modes: AcpGetConversationReturnModes?
    let agentInfo: AcpGetConversationReturnAgentInfo?
    let acpSandboxId: ConvexId<ConvexTableAcpSandboxes>?
    let initializedOnSandbox: Bool?
    @OptionalConvexFloat var lastMessageAt: Double?
    @OptionalConvexFloat var lastAssistantVisibleAt: Double?
    let teamId: String
    @ConvexFloat var createdAt: Double
    @ConvexFloat var updatedAt: Double
    let status: AcpGetConversationReturnStatusEnum
    let sessionId: String
    let providerId: String
    let cwd: String
}

struct AcpListMessagesReturnMessagesItemToolCallsItem: Decodable {
    @OptionalConvexFloat var acpSeq: Double?
    let result: String?
    let id: String
    let name: String
    let status: AcpListMessagesReturnMessagesItemToolCallsItemStatusEnum
    let arguments: String
}

struct AcpListMessagesReturnMessagesItemContentItemResource: Decodable {
    let text: String?
    let mimeType: String?
    let blob: String?
    let uri: String
}

struct AcpListMessagesReturnMessagesItemContentItemAnnotations: Decodable {
    let audience: [String]?
    let lastModified: String?
    @OptionalConvexFloat var priority: Double?
}

struct AcpListMessagesReturnMessagesItemContentItem: Decodable {
    let name: String?
    let text: String?
    let description: String?
    let mimeType: String?
    let title: String?
    let resource: AcpListMessagesReturnMessagesItemContentItemResource?
    let data: String?
    let uri: String?
    @OptionalConvexFloat var size: Double?
    let annotations: AcpListMessagesReturnMessagesItemContentItemAnnotations?
    @OptionalConvexFloat var acpSeq: Double?
    let type: AcpListMessagesReturnMessagesItemContentItemTypeEnum
}

struct AcpListMessagesReturnMessagesItem: Decodable {
    let _id: ConvexId<ConvexTableConversationMessages>
    @ConvexFloat var _creationTime: Double
    let clientMessageId: String?
    let deliveryStatus: AcpListMessagesReturnMessagesItemDeliveryStatusEnum?
    let deliveryError: String?
    let deliverySwapAttempted: Bool?
    @OptionalConvexFloat var acpSeq: Double?
    let toolCalls: [AcpListMessagesReturnMessagesItemToolCallsItem]?
    let reasoning: String?
    let isFinal: Bool?
    @ConvexFloat var createdAt: Double
    let role: AcpListMessagesReturnMessagesItemRoleEnum
    let content: [AcpListMessagesReturnMessagesItemContentItem]
    let conversationId: ConvexId<ConvexTableConversations>
}

struct AcpListMessagesReturn: Decodable {
    let messages: [AcpListMessagesReturnMessagesItem]
    let nextCursor: String
    let isDone: Bool
}

struct AcpSubscribeNewMessagesItemToolCallsItem: Decodable {
    @OptionalConvexFloat var acpSeq: Double?
    let result: String?
    let id: String
    let name: String
    let status: AcpSubscribeNewMessagesItemToolCallsItemStatusEnum
    let arguments: String
}

struct AcpSubscribeNewMessagesItemContentItemResource: Decodable {
    let text: String?
    let mimeType: String?
    let blob: String?
    let uri: String
}

struct AcpSubscribeNewMessagesItemContentItemAnnotations: Decodable {
    let audience: [String]?
    let lastModified: String?
    @OptionalConvexFloat var priority: Double?
}

struct AcpSubscribeNewMessagesItemContentItem: Decodable {
    let name: String?
    let text: String?
    let description: String?
    let mimeType: String?
    let title: String?
    let resource: AcpSubscribeNewMessagesItemContentItemResource?
    let data: String?
    let uri: String?
    @OptionalConvexFloat var size: Double?
    let annotations: AcpSubscribeNewMessagesItemContentItemAnnotations?
    @OptionalConvexFloat var acpSeq: Double?
    let type: AcpSubscribeNewMessagesItemContentItemTypeEnum
}

struct AcpSubscribeNewMessagesItem: Decodable {
    let _id: ConvexId<ConvexTableConversationMessages>
    @ConvexFloat var _creationTime: Double
    let clientMessageId: String?
    let deliveryStatus: AcpSubscribeNewMessagesItemDeliveryStatusEnum?
    let deliveryError: String?
    let deliverySwapAttempted: Bool?
    @OptionalConvexFloat var acpSeq: Double?
    let toolCalls: [AcpSubscribeNewMessagesItemToolCallsItem]?
    let reasoning: String?
    let isFinal: Bool?
    @ConvexFloat var createdAt: Double
    let role: AcpSubscribeNewMessagesItemRoleEnum
    let content: [AcpSubscribeNewMessagesItemContentItem]
    let conversationId: ConvexId<ConvexTableConversations>
}

struct AcpGetMessagesItemToolCallsItem: Decodable {
    @OptionalConvexFloat var acpSeq: Double?
    let result: String?
    let id: String
    let name: String
    let status: AcpGetMessagesItemToolCallsItemStatusEnum
    let arguments: String
}

struct AcpGetMessagesItemContentItemResource: Decodable {
    let text: String?
    let mimeType: String?
    let blob: String?
    let uri: String
}

struct AcpGetMessagesItemContentItemAnnotations: Decodable {
    let audience: [String]?
    let lastModified: String?
    @OptionalConvexFloat var priority: Double?
}

struct AcpGetMessagesItemContentItem: Decodable {
    let name: String?
    let text: String?
    let description: String?
    let mimeType: String?
    let title: String?
    let resource: AcpGetMessagesItemContentItemResource?
    let data: String?
    let uri: String?
    @OptionalConvexFloat var size: Double?
    let annotations: AcpGetMessagesItemContentItemAnnotations?
    @OptionalConvexFloat var acpSeq: Double?
    let type: AcpGetMessagesItemContentItemTypeEnum
}

struct AcpGetMessagesItem: Decodable {
    let _id: ConvexId<ConvexTableConversationMessages>
    @ConvexFloat var _creationTime: Double
    let clientMessageId: String?
    let deliveryStatus: AcpGetMessagesItemDeliveryStatusEnum?
    let deliveryError: String?
    let deliverySwapAttempted: Bool?
    @OptionalConvexFloat var acpSeq: Double?
    let toolCalls: [AcpGetMessagesItemToolCallsItem]?
    let reasoning: String?
    let isFinal: Bool?
    @ConvexFloat var createdAt: Double
    let role: AcpGetMessagesItemRoleEnum
    let content: [AcpGetMessagesItemContentItem]
    let conversationId: ConvexId<ConvexTableConversations>
}

struct AcpRawEventsListByConversationPaginatedArgsPaginationOpts: ConvexEncodable {
    let id: Double?
    let endCursor: String?
    let maximumRowsRead: Double?
    let maximumBytesRead: Double?
    let numItems: Double
    let cursor: String?

    func convexEncode() throws -> String {
        var result: [String: ConvexEncodable?] = [:]
        if let value = id { result["id"] = value }
        if let value = endCursor { result["endCursor"] = value }
        if let value = maximumRowsRead { result["maximumRowsRead"] = value }
        if let value = maximumBytesRead { result["maximumBytesRead"] = value }
        result["numItems"] = numItems
        if let value = cursor { result["cursor"] = value } else { result["cursor"] = ConvexNull() }
        return try result.convexEncode()
    }
}

struct AcpRawEventsListByConversationPaginatedReturnPageItem: Decodable {
    let _id: ConvexId<ConvexTableAcpRawEvents>
    @ConvexFloat var _creationTime: Double
    let direction: AcpRawEventsListByConversationPaginatedReturnPageItemDirectionEnum?
    let eventType: String?
    let teamId: String
    @ConvexFloat var createdAt: Double
    let conversationId: ConvexId<ConvexTableConversations>
    let sandboxId: ConvexId<ConvexTableAcpSandboxes>
    @ConvexFloat var seq: Double
    let raw: String
}

struct AcpRawEventsListByConversationPaginatedReturn: Decodable {
    let page: [AcpRawEventsListByConversationPaginatedReturnPageItem]
    let isDone: Bool
    let continueCursor: String
    let splitCursor: String?
    let pageStatus: AcpRawEventsListByConversationPaginatedReturnPageStatusEnum?
}

struct AcpRawEventsListByConversationFirstPageReturnPageItem: Decodable {
    let _id: ConvexId<ConvexTableAcpRawEvents>
    @ConvexFloat var _creationTime: Double
    let direction: AcpRawEventsListByConversationFirstPageReturnPageItemDirectionEnum?
    let eventType: String?
    let teamId: String
    @ConvexFloat var createdAt: Double
    let conversationId: ConvexId<ConvexTableConversations>
    let sandboxId: ConvexId<ConvexTableAcpSandboxes>
    @ConvexFloat var seq: Double
    let raw: String
}

struct AcpRawEventsListByConversationFirstPageReturn: Decodable {
    let page: [AcpRawEventsListByConversationFirstPageReturnPageItem]
    let isDone: Bool
    let continueCursor: String
    let splitCursor: String?
    let pageStatus: AcpRawEventsListByConversationFirstPageReturnPageStatusEnum?
}

struct AcpSandboxesListForTeamItem: Decodable {
    let _id: ConvexId<ConvexTableAcpSandboxes>
    @ConvexFloat var _creationTime: Double
    let sandboxUrl: String?
    let streamSecret: String?
    let lastError: String?
    let poolState: AcpSandboxesListForTeamItemPoolStateEnum?
    @OptionalConvexFloat var warmExpiresAt: Double?
    let warmReservedUserId: String?
    let warmReservedTeamId: String?
    @OptionalConvexFloat var warmReservedAt: Double?
    @OptionalConvexFloat var claimedAt: Double?
    let teamId: String
    @ConvexFloat var createdAt: Double
    @ConvexFloat var lastActivityAt: Double
    let status: AcpSandboxesListForTeamItemStatusEnum
    let provider: AcpSandboxesListForTeamItemProviderEnum
    let instanceId: String
    let callbackJwtHash: String
    @ConvexFloat var conversationCount: Double
    let snapshotId: String
}

struct AcpSandboxesGetReturn: Decodable {
    let _id: ConvexId<ConvexTableAcpSandboxes>
    @ConvexFloat var _creationTime: Double
    let sandboxUrl: String?
    let streamSecret: String?
    let lastError: String?
    let poolState: AcpSandboxesGetReturnPoolStateEnum?
    @OptionalConvexFloat var warmExpiresAt: Double?
    let warmReservedUserId: String?
    let warmReservedTeamId: String?
    @OptionalConvexFloat var warmReservedAt: Double?
    @OptionalConvexFloat var claimedAt: Double?
    let teamId: String
    @ConvexFloat var createdAt: Double
    @ConvexFloat var lastActivityAt: Double
    let status: AcpSandboxesGetReturnStatusEnum
    let provider: AcpSandboxesGetReturnProviderEnum
    let instanceId: String
    let callbackJwtHash: String
    @ConvexFloat var conversationCount: Double
    let snapshotId: String
}

struct ApiKeysGetAllItem: Decodable {
    let _id: ConvexId<ConvexTableApiKeys>
    @ConvexFloat var _creationTime: Double
    let description: String?
    let teamId: String
    let displayName: String
    @ConvexFloat var createdAt: Double
    @ConvexFloat var updatedAt: Double
    let userId: String
    let envVar: String
    let value: String
}

struct ApiKeysGetByEnvVarReturn: Decodable {
    let _id: ConvexId<ConvexTableApiKeys>
    @ConvexFloat var _creationTime: Double
    let description: String?
    let teamId: String
    let displayName: String
    @ConvexFloat var createdAt: Double
    @ConvexFloat var updatedAt: Double
    let userId: String
    let envVar: String
    let value: String
}

struct ApiKeysUpsertReturnTableName: Decodable {
    @ConvexFloat var length: Double
}

struct ApiKeysUpsertReturn: Decodable {
    @ConvexFloat var length: Double
    let __tableName: ApiKeysUpsertReturnTableName
}

struct CodeReviewReserveJobArgsComparison: ConvexEncodable {
    let slug: String
    let headRef: String
    let baseRef: String
    let baseOwner: String
    let headOwner: String

    func convexEncode() throws -> String {
        var result: [String: ConvexEncodable?] = [:]
        result["slug"] = slug
        result["headRef"] = headRef
        result["baseRef"] = baseRef
        result["baseOwner"] = baseOwner
        result["headOwner"] = headOwner
        return try result.convexEncode()
    }
}

struct CodeReviewReserveJobReturnJob: Decodable {
    let jobId: ConvexId<ConvexTableAutomatedCodeReviewJobs>
    let teamId: String?
    let repoFullName: String
    let repoUrl: String
    @OptionalConvexFloat var prNumber: Double?
    let commitRef: String
    let headCommitRef: String
    let baseCommitRef: String?
    let requestedByUserId: String
    let jobType: CodeReviewReserveJobReturnJobJobTypeEnum
    let comparisonSlug: String?
    let comparisonBaseOwner: String?
    let comparisonBaseRef: String?
    let comparisonHeadOwner: String?
    let comparisonHeadRef: String?
    let state: CodeReviewReserveJobReturnJobStateEnum
    @ConvexFloat var createdAt: Double
    @ConvexFloat var updatedAt: Double
    @OptionalConvexFloat var startedAt: Double?
    @OptionalConvexFloat var completedAt: Double?
    let sandboxInstanceId: String?
    let errorCode: String?
    let errorDetail: String?
    let codeReviewOutput: [String: String]?
}

struct CodeReviewReserveJobReturn: Decodable {
    let wasCreated: Bool
    let job: CodeReviewReserveJobReturnJob
}

struct CodeReviewMarkJobRunningReturn: Decodable {
    let jobId: ConvexId<ConvexTableAutomatedCodeReviewJobs>
    let teamId: String?
    let repoFullName: String
    let repoUrl: String
    @OptionalConvexFloat var prNumber: Double?
    let commitRef: String
    let headCommitRef: String
    let baseCommitRef: String?
    let requestedByUserId: String
    let jobType: CodeReviewMarkJobRunningReturnJobTypeEnum
    let comparisonSlug: String?
    let comparisonBaseOwner: String?
    let comparisonBaseRef: String?
    let comparisonHeadOwner: String?
    let comparisonHeadRef: String?
    let state: CodeReviewMarkJobRunningReturnStateEnum
    @ConvexFloat var createdAt: Double
    @ConvexFloat var updatedAt: Double
    @OptionalConvexFloat var startedAt: Double?
    @OptionalConvexFloat var completedAt: Double?
    let sandboxInstanceId: String?
    let errorCode: String?
    let errorDetail: String?
    let codeReviewOutput: [String: String]?
}

struct CodeReviewFailJobReturn: Decodable {
    let jobId: ConvexId<ConvexTableAutomatedCodeReviewJobs>
    let teamId: String?
    let repoFullName: String
    let repoUrl: String
    @OptionalConvexFloat var prNumber: Double?
    let commitRef: String
    let headCommitRef: String
    let baseCommitRef: String?
    let requestedByUserId: String
    let jobType: CodeReviewFailJobReturnJobTypeEnum
    let comparisonSlug: String?
    let comparisonBaseOwner: String?
    let comparisonBaseRef: String?
    let comparisonHeadOwner: String?
    let comparisonHeadRef: String?
    let state: CodeReviewFailJobReturnStateEnum
    @ConvexFloat var createdAt: Double
    @ConvexFloat var updatedAt: Double
    @OptionalConvexFloat var startedAt: Double?
    @OptionalConvexFloat var completedAt: Double?
    let sandboxInstanceId: String?
    let errorCode: String?
    let errorDetail: String?
    let codeReviewOutput: [String: String]?
}

struct CodeReviewUpsertFileOutputFromCallbackReturn: Decodable {
    let success: Bool
}

struct CodeReviewCompleteJobFromCallbackReturn: Decodable {
    let jobId: ConvexId<ConvexTableAutomatedCodeReviewJobs>
    let teamId: String?
    let repoFullName: String
    let repoUrl: String
    @OptionalConvexFloat var prNumber: Double?
    let commitRef: String
    let headCommitRef: String
    let baseCommitRef: String?
    let requestedByUserId: String
    let jobType: CodeReviewCompleteJobFromCallbackReturnJobTypeEnum
    let comparisonSlug: String?
    let comparisonBaseOwner: String?
    let comparisonBaseRef: String?
    let comparisonHeadOwner: String?
    let comparisonHeadRef: String?
    let state: CodeReviewCompleteJobFromCallbackReturnStateEnum
    @ConvexFloat var createdAt: Double
    @ConvexFloat var updatedAt: Double
    @OptionalConvexFloat var startedAt: Double?
    @OptionalConvexFloat var completedAt: Double?
    let sandboxInstanceId: String?
    let errorCode: String?
    let errorDetail: String?
    let codeReviewOutput: [String: String]?
}

struct CodeReviewFailJobFromCallbackReturn: Decodable {
    let jobId: ConvexId<ConvexTableAutomatedCodeReviewJobs>
    let teamId: String?
    let repoFullName: String
    let repoUrl: String
    @OptionalConvexFloat var prNumber: Double?
    let commitRef: String
    let headCommitRef: String
    let baseCommitRef: String?
    let requestedByUserId: String
    let jobType: CodeReviewFailJobFromCallbackReturnJobTypeEnum
    let comparisonSlug: String?
    let comparisonBaseOwner: String?
    let comparisonBaseRef: String?
    let comparisonHeadOwner: String?
    let comparisonHeadRef: String?
    let state: CodeReviewFailJobFromCallbackReturnStateEnum
    @ConvexFloat var createdAt: Double
    @ConvexFloat var updatedAt: Double
    @OptionalConvexFloat var startedAt: Double?
    @OptionalConvexFloat var completedAt: Double?
    let sandboxInstanceId: String?
    let errorCode: String?
    let errorDetail: String?
    let codeReviewOutput: [String: String]?
}

struct CodeReviewListFileOutputsForPrItem: Decodable {
    let id: ConvexId<ConvexTableAutomatedCodeReviewFileOutputs>
    let jobId: ConvexId<ConvexTableAutomatedCodeReviewJobs>
    let teamId: String?
    let repoFullName: String
    @OptionalConvexFloat var prNumber: Double?
    let commitRef: String
    let headCommitRef: String
    let baseCommitRef: String?
    let sandboxInstanceId: String?
    let filePath: String
    let codexReviewOutput: String
    let tooltipLanguage: String?
    @ConvexFloat var createdAt: Double
    @ConvexFloat var updatedAt: Double
}

struct CodeReviewListFileOutputsForComparisonItem: Decodable {
    let id: ConvexId<ConvexTableAutomatedCodeReviewFileOutputs>
    let jobId: ConvexId<ConvexTableAutomatedCodeReviewJobs>
    let teamId: String?
    let repoFullName: String
    @OptionalConvexFloat var prNumber: Double?
    let commitRef: String
    let headCommitRef: String
    let baseCommitRef: String?
    let sandboxInstanceId: String?
    let filePath: String
    let codexReviewOutput: String
    let tooltipLanguage: String?
    @ConvexFloat var createdAt: Double
    @ConvexFloat var updatedAt: Double
}

struct CodexTokensGetReturn: Decodable {
    let _id: ConvexId<ConvexTableCodexTokens>
    @ConvexFloat var _creationTime: Double
    let accountId: String?
    let email: String?
    let idToken: String?
    let planType: String?
    let teamId: String
    @ConvexFloat var createdAt: Double
    @ConvexFloat var updatedAt: Double
    let userId: String
    let accessToken: String
    let refreshToken: String
    @ConvexFloat var expiresAt: Double
    @ConvexFloat var lastRefresh: Double
}

struct CodexTokensSaveReturnTableName: Decodable {
    @ConvexFloat var length: Double
}

struct CodexTokensSaveReturn: Decodable {
    @ConvexFloat var length: Double
    let __tableName: CodexTokensSaveReturnTableName
}

struct CommentsCreateCommentReturnTableName: Decodable {
    @ConvexFloat var length: Double
}

struct CommentsCreateCommentReturn: Decodable {
    @ConvexFloat var length: Double
    let __tableName: CommentsCreateCommentReturnTableName
}

struct CommentsListCommentsItem: Decodable {
    let _id: ConvexId<ConvexTableComments>
    @ConvexFloat var _creationTime: Double
    let profileImageUrl: String?
    let resolved: Bool?
    let archived: Bool?
    let teamId: String
    @ConvexFloat var createdAt: Double
    @ConvexFloat var updatedAt: Double
    let userId: String
    let url: String
    let content: String
    let page: String
    let pageTitle: String
    let nodeId: String
    @ConvexFloat var x: Double
    @ConvexFloat var y: Double
    let userAgent: String
    @ConvexFloat var screenWidth: Double
    @ConvexFloat var screenHeight: Double
    @ConvexFloat var devicePixelRatio: Double
}

struct CommentsAddReplyReturnTableName: Decodable {
    @ConvexFloat var length: Double
}

struct CommentsAddReplyReturn: Decodable {
    @ConvexFloat var length: Double
    let __tableName: CommentsAddReplyReturnTableName
}

struct CommentsGetRepliesItem: Decodable {
    let _id: ConvexId<ConvexTableCommentReplies>
    @ConvexFloat var _creationTime: Double
    let teamId: String
    @ConvexFloat var createdAt: Double
    @ConvexFloat var updatedAt: Double
    let userId: String
    let content: String
    let commentId: ConvexId<ConvexTableComments>
}

struct ContainerSettingsGetReturn: Decodable {
    let _id: ConvexId<ConvexTableContainerSettings>?
    @ConvexFloat var createdAt: Double
    @ConvexFloat var updatedAt: Double
    @ConvexFloat var maxRunningContainers: Double
    @ConvexFloat var reviewPeriodMinutes: Double
    let autoCleanupEnabled: Bool
    let stopImmediatelyOnCompletion: Bool
    @ConvexFloat var minContainersToKeep: Double
}

struct ContainerSettingsGetEffectiveReturn: Decodable {
    @ConvexFloat var maxRunningContainers: Double
    @ConvexFloat var reviewPeriodMinutes: Double
    let autoCleanupEnabled: Bool
    let stopImmediatelyOnCompletion: Bool
    @ConvexFloat var minContainersToKeep: Double
}

struct ConversationMessagesListByConversationReturnMessagesItemToolCallsItem: Decodable {
    @OptionalConvexFloat var acpSeq: Double?
    let result: String?
    let id: String
    let name: String
    let status: ConversationMessagesListByConversationReturnMessagesItemToolCallsItemStatusEnum
    let arguments: String
}

struct ConversationMessagesListByConversationReturnMessagesItemContentItemResource: Decodable {
    let text: String?
    let mimeType: String?
    let blob: String?
    let uri: String
}

struct ConversationMessagesListByConversationReturnMessagesItemContentItemAnnotations: Decodable {
    let audience: [String]?
    let lastModified: String?
    @OptionalConvexFloat var priority: Double?
}

struct ConversationMessagesListByConversationReturnMessagesItemContentItem: Decodable {
    let name: String?
    let text: String?
    let description: String?
    let mimeType: String?
    let title: String?
    let resource: ConversationMessagesListByConversationReturnMessagesItemContentItemResource?
    let data: String?
    let uri: String?
    @OptionalConvexFloat var size: Double?
    let annotations: ConversationMessagesListByConversationReturnMessagesItemContentItemAnnotations?
    @OptionalConvexFloat var acpSeq: Double?
    let type: ConversationMessagesListByConversationReturnMessagesItemContentItemTypeEnum
}

struct ConversationMessagesListByConversationReturnMessagesItem: Decodable {
    let _id: ConvexId<ConvexTableConversationMessages>
    @ConvexFloat var _creationTime: Double
    let clientMessageId: String?
    let deliveryStatus: ConversationMessagesListByConversationReturnMessagesItemDeliveryStatusEnum?
    let deliveryError: String?
    let deliverySwapAttempted: Bool?
    @OptionalConvexFloat var acpSeq: Double?
    let toolCalls: [ConversationMessagesListByConversationReturnMessagesItemToolCallsItem]?
    let reasoning: String?
    let isFinal: Bool?
    @ConvexFloat var createdAt: Double
    let role: ConversationMessagesListByConversationReturnMessagesItemRoleEnum
    let content: [ConversationMessagesListByConversationReturnMessagesItemContentItem]
    let conversationId: ConvexId<ConvexTableConversations>
}

struct ConversationMessagesListByConversationReturn: Decodable {
    let messages: [ConversationMessagesListByConversationReturnMessagesItem]
    let nextCursor: String
    let isDone: Bool
}

struct ConversationMessagesListByConversationPaginatedArgsConversationId: ConvexEncodable {
    let length: Double

    func convexEncode() throws -> String {
        var result: [String: ConvexEncodable?] = [:]
        result["length"] = length
        return try result.convexEncode()
    }
}

struct ConversationMessagesListByConversationPaginatedArgsPaginationOpts: ConvexEncodable {
    let id: Double?
    let endCursor: String?
    let maximumRowsRead: Double?
    let maximumBytesRead: Double?
    let numItems: Double
    let cursor: String?

    func convexEncode() throws -> String {
        var result: [String: ConvexEncodable?] = [:]
        if let value = id { result["id"] = value }
        if let value = endCursor { result["endCursor"] = value }
        if let value = maximumRowsRead { result["maximumRowsRead"] = value }
        if let value = maximumBytesRead { result["maximumBytesRead"] = value }
        result["numItems"] = numItems
        if let value = cursor { result["cursor"] = value } else { result["cursor"] = ConvexNull() }
        return try result.convexEncode()
    }
}

struct ConversationMessagesListByConversationPaginatedReturnPageItemToolCallsItem: Decodable {
    @OptionalConvexFloat var acpSeq: Double?
    let result: String?
    let id: String
    let name: String
    let status: ConversationMessagesListByConversationPaginatedReturnPageItemToolCallsItemStatusEnum
    let arguments: String
}

struct ConversationMessagesListByConversationPaginatedReturnPageItemContentItemResource: Decodable {
    let text: String?
    let mimeType: String?
    let blob: String?
    let uri: String
}

struct ConversationMessagesListByConversationPaginatedReturnPageItemContentItemAnnotations: Decodable {
    let audience: [String]?
    let lastModified: String?
    @OptionalConvexFloat var priority: Double?
}

struct ConversationMessagesListByConversationPaginatedReturnPageItemContentItem: Decodable {
    let name: String?
    let text: String?
    let description: String?
    let mimeType: String?
    let title: String?
    let resource: ConversationMessagesListByConversationPaginatedReturnPageItemContentItemResource?
    let data: String?
    let uri: String?
    @OptionalConvexFloat var size: Double?
    let annotations: ConversationMessagesListByConversationPaginatedReturnPageItemContentItemAnnotations?
    @OptionalConvexFloat var acpSeq: Double?
    let type: ConversationMessagesListByConversationPaginatedReturnPageItemContentItemTypeEnum
}

struct ConversationMessagesListByConversationPaginatedReturnPageItem: Decodable {
    let _id: ConvexId<ConvexTableConversationMessages>
    @ConvexFloat var _creationTime: Double
    let clientMessageId: String?
    let deliveryStatus: ConversationMessagesListByConversationPaginatedReturnPageItemDeliveryStatusEnum?
    let deliveryError: String?
    let deliverySwapAttempted: Bool?
    @OptionalConvexFloat var acpSeq: Double?
    let toolCalls: [ConversationMessagesListByConversationPaginatedReturnPageItemToolCallsItem]?
    let reasoning: String?
    let isFinal: Bool?
    @ConvexFloat var createdAt: Double
    let role: ConversationMessagesListByConversationPaginatedReturnPageItemRoleEnum
    let content: [ConversationMessagesListByConversationPaginatedReturnPageItemContentItem]
    let conversationId: ConvexId<ConvexTableConversations>
}

struct ConversationMessagesListByConversationPaginatedReturn: Decodable {
    let page: [ConversationMessagesListByConversationPaginatedReturnPageItem]
    let isDone: Bool
    let continueCursor: String
    let splitCursor: String?
    let pageStatus: ConversationMessagesListByConversationPaginatedReturnPageStatusEnum?
}

struct ConversationMessagesListByConversationFirstPageArgsConversationId: ConvexEncodable {
    let length: Double

    func convexEncode() throws -> String {
        var result: [String: ConvexEncodable?] = [:]
        result["length"] = length
        return try result.convexEncode()
    }
}

struct ConversationMessagesListByConversationFirstPageReturnPageItemToolCallsItem: Decodable {
    @OptionalConvexFloat var acpSeq: Double?
    let result: String?
    let id: String
    let name: String
    let status: ConversationMessagesListByConversationFirstPageReturnPageItemToolCallsItemStatusEnum
    let arguments: String
}

struct ConversationMessagesListByConversationFirstPageReturnPageItemContentItemResource: Decodable {
    let text: String?
    let mimeType: String?
    let blob: String?
    let uri: String
}

struct ConversationMessagesListByConversationFirstPageReturnPageItemContentItemAnnotations: Decodable {
    let audience: [String]?
    let lastModified: String?
    @OptionalConvexFloat var priority: Double?
}

struct ConversationMessagesListByConversationFirstPageReturnPageItemContentItem: Decodable {
    let name: String?
    let text: String?
    let description: String?
    let mimeType: String?
    let title: String?
    let resource: ConversationMessagesListByConversationFirstPageReturnPageItemContentItemResource?
    let data: String?
    let uri: String?
    @OptionalConvexFloat var size: Double?
    let annotations: ConversationMessagesListByConversationFirstPageReturnPageItemContentItemAnnotations?
    @OptionalConvexFloat var acpSeq: Double?
    let type: ConversationMessagesListByConversationFirstPageReturnPageItemContentItemTypeEnum
}

struct ConversationMessagesListByConversationFirstPageReturnPageItem: Decodable {
    let _id: ConvexId<ConvexTableConversationMessages>
    @ConvexFloat var _creationTime: Double
    let clientMessageId: String?
    let deliveryStatus: ConversationMessagesListByConversationFirstPageReturnPageItemDeliveryStatusEnum?
    let deliveryError: String?
    let deliverySwapAttempted: Bool?
    @OptionalConvexFloat var acpSeq: Double?
    let toolCalls: [ConversationMessagesListByConversationFirstPageReturnPageItemToolCallsItem]?
    let reasoning: String?
    let isFinal: Bool?
    @ConvexFloat var createdAt: Double
    let role: ConversationMessagesListByConversationFirstPageReturnPageItemRoleEnum
    let content: [ConversationMessagesListByConversationFirstPageReturnPageItemContentItem]
    let conversationId: ConvexId<ConvexTableConversations>
}

struct ConversationMessagesListByConversationFirstPageReturn: Decodable {
    let page: [ConversationMessagesListByConversationFirstPageReturnPageItem]
    let isDone: Bool
    let continueCursor: String
    let splitCursor: String?
    let pageStatus: ConversationMessagesListByConversationFirstPageReturnPageStatusEnum?
}

struct ConversationReadsMarkReadReturn: Decodable {
    @ConvexFloat var lastReadAt: Double
}

struct ConversationReadsMarkUnreadReturn: Decodable {
    @ConvexFloat var lastReadAt: Double
}

struct ConversationsCreateReturn: Decodable {
    let conversationId: ConvexId<ConvexTableConversations>
    let jwt: String
}

struct ConversationsGetByIdReturnModesAvailableModesItem: Decodable {
    let description: String?
    let id: String
    let name: String
}

struct ConversationsGetByIdReturnModes: Decodable {
    let currentModeId: String
    let availableModes: [ConversationsGetByIdReturnModesAvailableModesItem]
}

struct ConversationsGetByIdReturnAgentInfo: Decodable {
    let title: String?
    let name: String
    let version: String
}

struct ConversationsGetByIdReturn: Decodable {
    let _id: ConvexId<ConvexTableConversations>
    @ConvexFloat var _creationTime: Double
    let userId: String?
    let isArchived: Bool?
    let pinned: Bool?
    let sandboxInstanceId: String?
    let title: String?
    let clientConversationId: String?
    let modelId: String?
    let permissionMode: ConversationsGetByIdReturnPermissionModeEnum?
    let stopReason: ConversationsGetByIdReturnStopReasonEnum?
    let namespaceId: String?
    let isolationMode: ConversationsGetByIdReturnIsolationModeEnum?
    let modes: ConversationsGetByIdReturnModes?
    let agentInfo: ConversationsGetByIdReturnAgentInfo?
    let acpSandboxId: ConvexId<ConvexTableAcpSandboxes>?
    let initializedOnSandbox: Bool?
    @OptionalConvexFloat var lastMessageAt: Double?
    @OptionalConvexFloat var lastAssistantVisibleAt: Double?
    let teamId: String
    @ConvexFloat var createdAt: Double
    @ConvexFloat var updatedAt: Double
    let status: ConversationsGetByIdReturnStatusEnum
    let sessionId: String
    let providerId: String
    let cwd: String
}

struct ConversationsGetDetailReturnConversationModesAvailableModesItem: Decodable {
    let description: String?
    let id: String
    let name: String
}

struct ConversationsGetDetailReturnConversationModes: Decodable {
    let currentModeId: String
    let availableModes: [ConversationsGetDetailReturnConversationModesAvailableModesItem]
}

struct ConversationsGetDetailReturnConversationAgentInfo: Decodable {
    let title: String?
    let name: String
    let version: String
}

struct ConversationsGetDetailReturnConversation: Decodable {
    let _id: ConvexId<ConvexTableConversations>
    @ConvexFloat var _creationTime: Double
    let userId: String?
    let isArchived: Bool?
    let pinned: Bool?
    let sandboxInstanceId: String?
    let title: String?
    let clientConversationId: String?
    let modelId: String?
    let permissionMode: ConversationsGetDetailReturnConversationPermissionModeEnum?
    let stopReason: ConversationsGetDetailReturnConversationStopReasonEnum?
    let namespaceId: String?
    let isolationMode: ConversationsGetDetailReturnConversationIsolationModeEnum?
    let modes: ConversationsGetDetailReturnConversationModes?
    let agentInfo: ConversationsGetDetailReturnConversationAgentInfo?
    let acpSandboxId: ConvexId<ConvexTableAcpSandboxes>?
    let initializedOnSandbox: Bool?
    @OptionalConvexFloat var lastMessageAt: Double?
    @OptionalConvexFloat var lastAssistantVisibleAt: Double?
    let teamId: String
    @ConvexFloat var createdAt: Double
    @ConvexFloat var updatedAt: Double
    let status: ConversationsGetDetailReturnConversationStatusEnum
    let sessionId: String
    let providerId: String
    let cwd: String
}

struct ConversationsGetDetailReturnSandbox: Decodable {
    let status: ConversationsGetDetailReturnSandboxStatusEnum
    let sandboxUrl: String?
    @ConvexFloat var lastActivityAt: Double
    let errorMessage: String?
}

struct ConversationsGetDetailReturn: Decodable {
    let conversation: ConversationsGetDetailReturnConversation
    let sandbox: ConversationsGetDetailReturnSandbox?
    @OptionalConvexFloat var lastReadAt: Double?
}

struct ConversationsGetBySessionIdReturnModesAvailableModesItem: Decodable {
    let description: String?
    let id: String
    let name: String
}

struct ConversationsGetBySessionIdReturnModes: Decodable {
    let currentModeId: String
    let availableModes: [ConversationsGetBySessionIdReturnModesAvailableModesItem]
}

struct ConversationsGetBySessionIdReturnAgentInfo: Decodable {
    let title: String?
    let name: String
    let version: String
}

struct ConversationsGetBySessionIdReturn: Decodable {
    let _id: ConvexId<ConvexTableConversations>
    @ConvexFloat var _creationTime: Double
    let userId: String?
    let isArchived: Bool?
    let pinned: Bool?
    let sandboxInstanceId: String?
    let title: String?
    let clientConversationId: String?
    let modelId: String?
    let permissionMode: ConversationsGetBySessionIdReturnPermissionModeEnum?
    let stopReason: ConversationsGetBySessionIdReturnStopReasonEnum?
    let namespaceId: String?
    let isolationMode: ConversationsGetBySessionIdReturnIsolationModeEnum?
    let modes: ConversationsGetBySessionIdReturnModes?
    let agentInfo: ConversationsGetBySessionIdReturnAgentInfo?
    let acpSandboxId: ConvexId<ConvexTableAcpSandboxes>?
    let initializedOnSandbox: Bool?
    @OptionalConvexFloat var lastMessageAt: Double?
    @OptionalConvexFloat var lastAssistantVisibleAt: Double?
    let teamId: String
    @ConvexFloat var createdAt: Double
    @ConvexFloat var updatedAt: Double
    let status: ConversationsGetBySessionIdReturnStatusEnum
    let sessionId: String
    let providerId: String
    let cwd: String
}

struct ConversationsListPagedWithLatestArgsPaginationOpts: ConvexEncodable {
    let id: Double?
    let endCursor: String?
    let maximumRowsRead: Double?
    let maximumBytesRead: Double?
    let numItems: Double
    let cursor: String?

    func convexEncode() throws -> String {
        var result: [String: ConvexEncodable?] = [:]
        if let value = id { result["id"] = value }
        if let value = endCursor { result["endCursor"] = value }
        if let value = maximumRowsRead { result["maximumRowsRead"] = value }
        if let value = maximumBytesRead { result["maximumBytesRead"] = value }
        result["numItems"] = numItems
        if let value = cursor { result["cursor"] = value } else { result["cursor"] = ConvexNull() }
        return try result.convexEncode()
    }
}

struct ConversationsListPagedWithLatestReturnPageItemConversationModesAvailableModesItem: Decodable {
    let description: String?
    let id: String
    let name: String
}

struct ConversationsListPagedWithLatestReturnPageItemConversationModes: Decodable {
    let currentModeId: String
    let availableModes: [ConversationsListPagedWithLatestReturnPageItemConversationModesAvailableModesItem]
}

struct ConversationsListPagedWithLatestReturnPageItemConversationAgentInfo: Decodable {
    let title: String?
    let name: String
    let version: String
}

struct ConversationsListPagedWithLatestReturnPageItemConversation: Decodable {
    let _id: ConvexId<ConvexTableConversations>
    @ConvexFloat var _creationTime: Double
    let userId: String?
    let isArchived: Bool?
    let pinned: Bool?
    let sandboxInstanceId: String?
    let title: String?
    let clientConversationId: String?
    let modelId: String?
    let permissionMode: ConversationsListPagedWithLatestReturnPageItemConversationPermissionModeEnum?
    let stopReason: ConversationsListPagedWithLatestReturnPageItemConversationStopReasonEnum?
    let namespaceId: String?
    let isolationMode: ConversationsListPagedWithLatestReturnPageItemConversationIsolationModeEnum?
    let modes: ConversationsListPagedWithLatestReturnPageItemConversationModes?
    let agentInfo: ConversationsListPagedWithLatestReturnPageItemConversationAgentInfo?
    let acpSandboxId: ConvexId<ConvexTableAcpSandboxes>?
    let initializedOnSandbox: Bool?
    @OptionalConvexFloat var lastMessageAt: Double?
    @OptionalConvexFloat var lastAssistantVisibleAt: Double?
    let teamId: String
    @ConvexFloat var createdAt: Double
    @ConvexFloat var updatedAt: Double
    let status: ConversationsListPagedWithLatestReturnPageItemConversationStatusEnum
    let sessionId: String
    let providerId: String
    let cwd: String
}

struct ConversationsListPagedWithLatestReturnPageItemPreview: Decodable {
    let text: String?
    let kind: ConversationsListPagedWithLatestReturnPageItemPreviewKindEnum
}

struct ConversationsListPagedWithLatestReturnPageItem: Decodable {
    let conversation: ConversationsListPagedWithLatestReturnPageItemConversation
    let preview: ConversationsListPagedWithLatestReturnPageItemPreview
    let unread: Bool
    @OptionalConvexFloat var lastReadAt: Double?
    @ConvexFloat var latestMessageAt: Double
    let title: String?
}

struct ConversationsListPagedWithLatestReturn: Decodable {
    let page: [ConversationsListPagedWithLatestReturnPageItem]
    let isDone: Bool
    let continueCursor: String
    let splitCursor: String?
    let pageStatus: ConversationsListPagedWithLatestReturnPageStatusEnum?
}

struct ConversationsListByNamespaceItemModesAvailableModesItem: Decodable {
    let description: String?
    let id: String
    let name: String
}

struct ConversationsListByNamespaceItemModes: Decodable {
    let currentModeId: String
    let availableModes: [ConversationsListByNamespaceItemModesAvailableModesItem]
}

struct ConversationsListByNamespaceItemAgentInfo: Decodable {
    let title: String?
    let name: String
    let version: String
}

struct ConversationsListByNamespaceItem: Decodable {
    let _id: ConvexId<ConvexTableConversations>
    @ConvexFloat var _creationTime: Double
    let userId: String?
    let isArchived: Bool?
    let pinned: Bool?
    let sandboxInstanceId: String?
    let title: String?
    let clientConversationId: String?
    let modelId: String?
    let permissionMode: ConversationsListByNamespaceItemPermissionModeEnum?
    let stopReason: ConversationsListByNamespaceItemStopReasonEnum?
    let namespaceId: String?
    let isolationMode: ConversationsListByNamespaceItemIsolationModeEnum?
    let modes: ConversationsListByNamespaceItemModes?
    let agentInfo: ConversationsListByNamespaceItemAgentInfo?
    let acpSandboxId: ConvexId<ConvexTableAcpSandboxes>?
    let initializedOnSandbox: Bool?
    @OptionalConvexFloat var lastMessageAt: Double?
    @OptionalConvexFloat var lastAssistantVisibleAt: Double?
    let teamId: String
    @ConvexFloat var createdAt: Double
    @ConvexFloat var updatedAt: Double
    let status: ConversationsListByNamespaceItemStatusEnum
    let sessionId: String
    let providerId: String
    let cwd: String
}

struct ConversationsListBySandboxItemModesAvailableModesItem: Decodable {
    let description: String?
    let id: String
    let name: String
}

struct ConversationsListBySandboxItemModes: Decodable {
    let currentModeId: String
    let availableModes: [ConversationsListBySandboxItemModesAvailableModesItem]
}

struct ConversationsListBySandboxItemAgentInfo: Decodable {
    let title: String?
    let name: String
    let version: String
}

struct ConversationsListBySandboxItem: Decodable {
    let _id: ConvexId<ConvexTableConversations>
    @ConvexFloat var _creationTime: Double
    let userId: String?
    let isArchived: Bool?
    let pinned: Bool?
    let sandboxInstanceId: String?
    let title: String?
    let clientConversationId: String?
    let modelId: String?
    let permissionMode: ConversationsListBySandboxItemPermissionModeEnum?
    let stopReason: ConversationsListBySandboxItemStopReasonEnum?
    let namespaceId: String?
    let isolationMode: ConversationsListBySandboxItemIsolationModeEnum?
    let modes: ConversationsListBySandboxItemModes?
    let agentInfo: ConversationsListBySandboxItemAgentInfo?
    let acpSandboxId: ConvexId<ConvexTableAcpSandboxes>?
    let initializedOnSandbox: Bool?
    @OptionalConvexFloat var lastMessageAt: Double?
    @OptionalConvexFloat var lastAssistantVisibleAt: Double?
    let teamId: String
    @ConvexFloat var createdAt: Double
    @ConvexFloat var updatedAt: Double
    let status: ConversationsListBySandboxItemStatusEnum
    let sessionId: String
    let providerId: String
    let cwd: String
}

struct ConversationsUpdatePermissionModeReturn: Decodable {
    let success: Bool
}

struct ConversationsRenameReturn: Decodable {
    let success: Bool
}

struct ConversationsPinReturn: Decodable {
    let success: Bool
}

struct ConversationsUnpinReturn: Decodable {
    let success: Bool
}

struct ConversationsArchiveReturn: Decodable {
    let success: Bool
}

struct ConversationsUnarchiveReturn: Decodable {
    let success: Bool
}

struct ConversationsRemoveReturn: Decodable {
    let success: Bool
}

struct ConversationsGetFullConversationReturnConversationModesAvailableModesItem: Decodable {
    let description: String?
    let id: String
    let name: String
}

struct ConversationsGetFullConversationReturnConversationModes: Decodable {
    let currentModeId: String
    let availableModes: [ConversationsGetFullConversationReturnConversationModesAvailableModesItem]
}

struct ConversationsGetFullConversationReturnConversationAgentInfo: Decodable {
    let title: String?
    let name: String
    let version: String
}

struct ConversationsGetFullConversationReturnConversation: Decodable {
    let _id: ConvexId<ConvexTableConversations>
    @ConvexFloat var _creationTime: Double
    let userId: String?
    let isArchived: Bool?
    let pinned: Bool?
    let sandboxInstanceId: String?
    let title: String?
    let clientConversationId: String?
    let modelId: String?
    let permissionMode: ConversationsGetFullConversationReturnConversationPermissionModeEnum?
    let stopReason: ConversationsGetFullConversationReturnConversationStopReasonEnum?
    let namespaceId: String?
    let isolationMode: ConversationsGetFullConversationReturnConversationIsolationModeEnum?
    let modes: ConversationsGetFullConversationReturnConversationModes?
    let agentInfo: ConversationsGetFullConversationReturnConversationAgentInfo?
    let acpSandboxId: ConvexId<ConvexTableAcpSandboxes>?
    let initializedOnSandbox: Bool?
    @OptionalConvexFloat var lastMessageAt: Double?
    @OptionalConvexFloat var lastAssistantVisibleAt: Double?
    let teamId: String
    @ConvexFloat var createdAt: Double
    @ConvexFloat var updatedAt: Double
    let status: ConversationsGetFullConversationReturnConversationStatusEnum
    let sessionId: String
    let providerId: String
    let cwd: String
}

struct ConversationsGetFullConversationReturnSandbox: Decodable {
    let status: ConversationsGetFullConversationReturnSandboxStatusEnum
    let sandboxUrl: String?
    @ConvexFloat var lastActivityAt: Double
    let errorMessage: String?
}

struct ConversationsGetFullConversationReturnMessagesItemToolCallsItem: Decodable {
    @OptionalConvexFloat var acpSeq: Double?
    let result: String?
    let id: String
    let name: String
    let status: ConversationsGetFullConversationReturnMessagesItemToolCallsItemStatusEnum
    let arguments: String
}

struct ConversationsGetFullConversationReturnMessagesItemContentItemResource: Decodable {
    let text: String?
    let mimeType: String?
    let blob: String?
    let uri: String
}

struct ConversationsGetFullConversationReturnMessagesItemContentItemAnnotations: Decodable {
    let audience: [String]?
    let lastModified: String?
    @OptionalConvexFloat var priority: Double?
}

struct ConversationsGetFullConversationReturnMessagesItemContentItem: Decodable {
    let name: String?
    let text: String?
    let description: String?
    let mimeType: String?
    let title: String?
    let resource: ConversationsGetFullConversationReturnMessagesItemContentItemResource?
    let data: String?
    let uri: String?
    @OptionalConvexFloat var size: Double?
    let annotations: ConversationsGetFullConversationReturnMessagesItemContentItemAnnotations?
    @OptionalConvexFloat var acpSeq: Double?
    let type: ConversationsGetFullConversationReturnMessagesItemContentItemTypeEnum
}

struct ConversationsGetFullConversationReturnMessagesItem: Decodable {
    let _id: ConvexId<ConvexTableConversationMessages>
    @ConvexFloat var _creationTime: Double
    let clientMessageId: String?
    let deliveryStatus: ConversationsGetFullConversationReturnMessagesItemDeliveryStatusEnum?
    let deliveryError: String?
    let deliverySwapAttempted: Bool?
    @OptionalConvexFloat var acpSeq: Double?
    let toolCalls: [ConversationsGetFullConversationReturnMessagesItemToolCallsItem]?
    let reasoning: String?
    let isFinal: Bool?
    @ConvexFloat var createdAt: Double
    let role: ConversationsGetFullConversationReturnMessagesItemRoleEnum
    let content: [ConversationsGetFullConversationReturnMessagesItemContentItem]
    let conversationId: ConvexId<ConvexTableConversations>
}

struct ConversationsGetFullConversationReturnRawEventsItem: Decodable {
    let _id: ConvexId<ConvexTableAcpRawEvents>
    @ConvexFloat var _creationTime: Double
    let direction: ConversationsGetFullConversationReturnRawEventsItemDirectionEnum?
    let eventType: String?
    let teamId: String
    @ConvexFloat var createdAt: Double
    let conversationId: ConvexId<ConvexTableConversations>
    let sandboxId: ConvexId<ConvexTableAcpSandboxes>
    @ConvexFloat var seq: Double
    let raw: String
}

struct ConversationsGetFullConversationReturnStreamInfo: Decodable {
    let sandboxUrl: String?
    let token: String?
    let status: String
}

struct ConversationsGetFullConversationReturn: Decodable {
    let conversation: ConversationsGetFullConversationReturnConversation
    let sandbox: ConversationsGetFullConversationReturnSandbox?
    @OptionalConvexFloat var lastReadAt: Double?
    let messages: [ConversationsGetFullConversationReturnMessagesItem]
    let rawEvents: [ConversationsGetFullConversationReturnRawEventsItem]
    let streamInfo: ConversationsGetFullConversationReturnStreamInfo
}

struct CrownEvaluateAndCrownWinnerReturn: Decodable {
    @ConvexFloat var length: Double
}

struct CrownSetCrownWinnerReturnTableName: Decodable {
    @ConvexFloat var length: Double
}

struct CrownSetCrownWinnerReturn: Decodable {
    @ConvexFloat var length: Double
    let __tableName: CrownSetCrownWinnerReturnTableName
}

struct CrownGetCrownedRunReturnEnvironmentError: Decodable {
    let devError: String?
    let maintenanceError: String?
}

struct CrownGetCrownedRunReturnPullRequestsItem: Decodable {
    @OptionalConvexFloat var number: Double?
    let url: String?
    let isDraft: Bool?
    let repoFullName: String
    let state: CrownGetCrownedRunReturnPullRequestsItemStateEnum
}

struct CrownGetCrownedRunReturnClaimsItemEvidence: Decodable {
    @OptionalConvexFloat var screenshotIndex: Double?
    let filePath: String?
    @OptionalConvexFloat var startLine: Double?
    @OptionalConvexFloat var endLine: Double?
    let type: String
}

struct CrownGetCrownedRunReturnClaimsItem: Decodable {
    let claim: String
    let evidence: CrownGetCrownedRunReturnClaimsItemEvidence
    @ConvexFloat var timestamp: Double
}

struct CrownGetCrownedRunReturnVscodePorts: Decodable {
    let `extension`: String?
    let proxy: String?
    let vnc: String?
    let vscode: String
    let worker: String
}

struct CrownGetCrownedRunReturnVscode: Decodable {
    let url: String?
    let containerName: String?
    let statusMessage: String?
    let ports: CrownGetCrownedRunReturnVscodePorts?
    let workspaceUrl: String?
    @OptionalConvexFloat var startedAt: Double?
    @OptionalConvexFloat var stoppedAt: Double?
    @OptionalConvexFloat var lastAccessedAt: Double?
    let keepAlive: Bool?
    @OptionalConvexFloat var scheduledStopAt: Double?
    let status: CrownGetCrownedRunReturnVscodeStatusEnum
    let provider: CrownGetCrownedRunReturnVscodeProviderEnum
}

struct CrownGetCrownedRunReturnNetworkingItem: Decodable {
    let status: CrownGetCrownedRunReturnNetworkingItemStatusEnum
    let url: String
    @ConvexFloat var port: Double
}

struct CrownGetCrownedRunReturnCustomPreviewsItem: Decodable {
    @ConvexFloat var createdAt: Double
    let url: String
}

struct CrownGetCrownedRunReturn: Decodable {
    let _id: ConvexId<ConvexTableTaskRuns>
    @ConvexFloat var _creationTime: Double
    let isArchived: Bool?
    let isLocalWorkspace: Bool?
    let isCloudWorkspace: Bool?
    let worktreePath: String?
    let environmentId: ConvexId<ConvexTableEnvironments>?
    let screenshotStorageId: ConvexId<ConvexTableStorage>?
    let screenshotMimeType: String?
    let screenshotFileName: String?
    let screenshotCommitSha: String?
    let latestScreenshotSetId: ConvexId<ConvexTableTaskRunScreenshotSets>?
    let parentRunId: ConvexId<ConvexTableTaskRuns>?
    let agentName: String?
    let summary: String?
    let isPreviewJob: Bool?
    let log: String?
    let newBranch: String?
    @OptionalConvexFloat var completedAt: Double?
    @OptionalConvexFloat var exitCode: Double?
    let environmentError: CrownGetCrownedRunReturnEnvironmentError?
    let errorMessage: String?
    let isCrowned: Bool?
    let crownReason: String?
    let pullRequestUrl: String?
    let pullRequestIsDraft: Bool?
    let pullRequestState: CrownGetCrownedRunReturnPullRequestStateEnum?
    @OptionalConvexFloat var pullRequestNumber: Double?
    let pullRequests: [CrownGetCrownedRunReturnPullRequestsItem]?
    @OptionalConvexFloat var diffsLastUpdated: Double?
    @OptionalConvexFloat var screenshotCapturedAt: Double?
    let claims: [CrownGetCrownedRunReturnClaimsItem]?
    @OptionalConvexFloat var claimsGeneratedAt: Double?
    let vscode: CrownGetCrownedRunReturnVscode?
    let networking: [CrownGetCrownedRunReturnNetworkingItem]?
    let customPreviews: [CrownGetCrownedRunReturnCustomPreviewsItem]?
    let teamId: String
    @ConvexFloat var createdAt: Double
    @ConvexFloat var updatedAt: Double
    let userId: String
    let taskId: ConvexId<ConvexTableTasks>
    let prompt: String
    let status: CrownGetCrownedRunReturnStatusEnum
}

struct CrownGetCrownEvaluationArgsTaskId: ConvexEncodable {
    let length: Double

    func convexEncode() throws -> String {
        var result: [String: ConvexEncodable?] = [:]
        result["length"] = length
        return try result.convexEncode()
    }
}

struct CrownGetCrownEvaluationReturn: Decodable {
    let _id: ConvexId<ConvexTableCrownEvaluations>
    @ConvexFloat var _creationTime: Double
    let teamId: String
    @ConvexFloat var createdAt: Double
    let userId: String
    let taskId: ConvexId<ConvexTableTasks>
    @ConvexFloat var evaluatedAt: Double
    let winnerRunId: ConvexId<ConvexTableTaskRuns>
    let candidateRunIds: [ConvexId<ConvexTableTaskRuns>]
    let evaluationPrompt: String
    let evaluationResponse: String
}

struct CrownActionsEvaluateArgsCandidatesItem: ConvexEncodable {
    let index: Double?
    let agentName: String?
    let newBranch: String?
    let runId: String?
    let modelName: String?
    let gitDiff: String

    func convexEncode() throws -> String {
        var result: [String: ConvexEncodable?] = [:]
        if let value = index { result["index"] = value }
        if let value = agentName { result["agentName"] = value }
        if let value = newBranch { result["newBranch"] = value }
        if let value = runId { result["runId"] = value }
        if let value = modelName { result["modelName"] = value }
        result["gitDiff"] = gitDiff
        return try result.convexEncode()
    }
}

struct CrownActionsEvaluateReturn: Decodable {
    @ConvexFloat var winner: Double
    let reason: String
}

struct CrownActionsSummarizeReturn: Decodable {
    let summary: String
}

struct DevboxInstancesListItem: Decodable {
    let _id: ConvexId<ConvexTableDevboxInstances>
    @ConvexFloat var _creationTime: Double
    let name: String?
    let environmentId: ConvexId<ConvexTableEnvironments>?
    @OptionalConvexFloat var stoppedAt: Double?
    @OptionalConvexFloat var lastAccessedAt: Double?
    let source: DevboxInstancesListItemSourceEnum?
    let metadata: [String: String]?
    let teamId: String
    @ConvexFloat var createdAt: Double
    @ConvexFloat var updatedAt: Double
    let userId: String
    let status: DevboxInstancesListItemStatusEnum
    let devboxId: String
}

struct DevboxInstancesGetByIdReturn: Decodable {
    let _id: ConvexId<ConvexTableDevboxInstances>
    @ConvexFloat var _creationTime: Double
    let name: String?
    let environmentId: ConvexId<ConvexTableEnvironments>?
    @OptionalConvexFloat var stoppedAt: Double?
    @OptionalConvexFloat var lastAccessedAt: Double?
    let source: DevboxInstancesGetByIdReturnSourceEnum?
    let metadata: [String: String]?
    let teamId: String
    @ConvexFloat var createdAt: Double
    @ConvexFloat var updatedAt: Double
    let userId: String
    let status: DevboxInstancesGetByIdReturnStatusEnum
    let devboxId: String
}

struct DevboxInstancesGetByProviderInstanceIdReturn: Decodable {
    let provider: DevboxInstancesGetByProviderInstanceIdReturnProviderEnum
    let providerInstanceId: String
    let _id: ConvexId<ConvexTableDevboxInstances>
    @ConvexFloat var _creationTime: Double
    let name: String?
    let environmentId: ConvexId<ConvexTableEnvironments>?
    @OptionalConvexFloat var stoppedAt: Double?
    @OptionalConvexFloat var lastAccessedAt: Double?
    let source: DevboxInstancesGetByProviderInstanceIdReturnSourceEnum?
    let metadata: [String: String]?
    let teamId: String
    @ConvexFloat var createdAt: Double
    @ConvexFloat var updatedAt: Double
    let userId: String
    let status: DevboxInstancesGetByProviderInstanceIdReturnStatusEnum
    let devboxId: String
}

struct DevboxInstancesCreateReturn: Decodable {
    let id: String
    let isExisting: Bool
}

struct E2bInstancesGetActivityReturn: Decodable {
    let _id: ConvexId<ConvexTableE2bInstanceActivity>
    @ConvexFloat var _creationTime: Double
    @OptionalConvexFloat var stoppedAt: Double?
    @OptionalConvexFloat var lastPausedAt: Double?
    @OptionalConvexFloat var lastResumedAt: Double?
    let instanceId: String
}

struct EnvironmentSnapshotsListItem: Decodable {
    let isActive: Bool
    let _id: ConvexId<ConvexTableEnvironmentSnapshotVersions>
    @ConvexFloat var _creationTime: Double
    let maintenanceScript: String?
    let devScript: String?
    let label: String?
    let teamId: String
    @ConvexFloat var createdAt: Double
    let environmentId: ConvexId<ConvexTableEnvironments>
    @ConvexFloat var version: Double
    let createdByUserId: String
    let morphSnapshotId: String
}

struct EnvironmentSnapshotsCreateReturn: Decodable {
    let snapshotVersionId: ConvexId<ConvexTableEnvironmentSnapshotVersions>
    @ConvexFloat var version: Double
}

struct EnvironmentSnapshotsActivateReturn: Decodable {
    let morphSnapshotId: String
    @ConvexFloat var version: Double
}

struct EnvironmentSnapshotsFindBySnapshotIdReturn: Decodable {
    let _id: ConvexId<ConvexTableEnvironmentSnapshotVersions>
    @ConvexFloat var _creationTime: Double
    let maintenanceScript: String?
    let devScript: String?
    let label: String?
    let teamId: String
    @ConvexFloat var createdAt: Double
    let environmentId: ConvexId<ConvexTableEnvironments>
    @ConvexFloat var version: Double
    let createdByUserId: String
    let morphSnapshotId: String
}

struct EnvironmentsListItem: Decodable {
    let _id: ConvexId<ConvexTableEnvironments>
    @ConvexFloat var _creationTime: Double
    let description: String?
    let maintenanceScript: String?
    let selectedRepos: [String]?
    let devScript: String?
    let exposedPorts: [Double]?
    let teamId: String
    let name: String
    @ConvexFloat var createdAt: Double
    @ConvexFloat var updatedAt: Double
    let userId: String
    let dataVaultKey: String
    let morphSnapshotId: String
}

struct EnvironmentsGetReturn: Decodable {
    let _id: ConvexId<ConvexTableEnvironments>
    @ConvexFloat var _creationTime: Double
    let description: String?
    let maintenanceScript: String?
    let selectedRepos: [String]?
    let devScript: String?
    let exposedPorts: [Double]?
    let teamId: String
    let name: String
    @ConvexFloat var createdAt: Double
    @ConvexFloat var updatedAt: Double
    let userId: String
    let dataVaultKey: String
    let morphSnapshotId: String
}

struct EnvironmentsCreateReturnTableName: Decodable {
    @ConvexFloat var length: Double
}

struct EnvironmentsCreateReturn: Decodable {
    @ConvexFloat var length: Double
    let __tableName: EnvironmentsCreateReturnTableName
}

struct EnvironmentsUpdateReturnTableName: Decodable {
    @ConvexFloat var length: Double
}

struct EnvironmentsUpdateReturn: Decodable {
    @ConvexFloat var length: Double
    let __tableName: EnvironmentsUpdateReturnTableName
}

struct EnvironmentsGetByDataVaultKeyReturn: Decodable {
    let _id: ConvexId<ConvexTableEnvironments>
    @ConvexFloat var _creationTime: Double
    let description: String?
    let maintenanceScript: String?
    let selectedRepos: [String]?
    let devScript: String?
    let exposedPorts: [Double]?
    let teamId: String
    let name: String
    @ConvexFloat var createdAt: Double
    @ConvexFloat var updatedAt: Double
    let userId: String
    let dataVaultKey: String
    let morphSnapshotId: String
}

struct GithubGetReposByOrgReturnValueItem: Decodable {
    let _id: ConvexId<ConvexTableRepos>
    @ConvexFloat var _creationTime: Double
    let provider: String?
    @OptionalConvexFloat var providerRepoId: Double?
    let ownerLogin: String?
    let ownerType: GithubGetReposByOrgReturnValueItemOwnerTypeEnum?
    let visibility: GithubGetReposByOrgReturnValueItemVisibilityEnum?
    let defaultBranch: String?
    let connectionId: ConvexId<ConvexTableProviderConnections>?
    @OptionalConvexFloat var lastSyncedAt: Double?
    @OptionalConvexFloat var lastPushedAt: Double?
    let manual: Bool?
    let teamId: String
    let name: String
    let userId: String
    let fullName: String
    let org: String
    let gitRemote: String
}

struct GithubGetRepoByFullNameReturn: Decodable {
    let _id: ConvexId<ConvexTableRepos>
    @ConvexFloat var _creationTime: Double
    let provider: String?
    @OptionalConvexFloat var providerRepoId: Double?
    let ownerLogin: String?
    let ownerType: GithubGetRepoByFullNameReturnOwnerTypeEnum?
    let visibility: GithubGetRepoByFullNameReturnVisibilityEnum?
    let defaultBranch: String?
    let connectionId: ConvexId<ConvexTableProviderConnections>?
    @OptionalConvexFloat var lastSyncedAt: Double?
    @OptionalConvexFloat var lastPushedAt: Double?
    let manual: Bool?
    let teamId: String
    let name: String
    let userId: String
    let fullName: String
    let org: String
    let gitRemote: String
}

struct GithubGetAllReposItem: Decodable {
    let _id: ConvexId<ConvexTableRepos>
    @ConvexFloat var _creationTime: Double
    let provider: String?
    @OptionalConvexFloat var providerRepoId: Double?
    let ownerLogin: String?
    let ownerType: GithubGetAllReposItemOwnerTypeEnum?
    let visibility: GithubGetAllReposItemVisibilityEnum?
    let defaultBranch: String?
    let connectionId: ConvexId<ConvexTableProviderConnections>?
    @OptionalConvexFloat var lastSyncedAt: Double?
    @OptionalConvexFloat var lastPushedAt: Double?
    let manual: Bool?
    let teamId: String
    let name: String
    let userId: String
    let fullName: String
    let org: String
    let gitRemote: String
}

struct GithubGetReposByInstallationItem: Decodable {
    let _id: ConvexId<ConvexTableRepos>
    @ConvexFloat var _creationTime: Double
    let provider: String?
    @OptionalConvexFloat var providerRepoId: Double?
    let ownerLogin: String?
    let ownerType: GithubGetReposByInstallationItemOwnerTypeEnum?
    let visibility: GithubGetReposByInstallationItemVisibilityEnum?
    let defaultBranch: String?
    let connectionId: ConvexId<ConvexTableProviderConnections>?
    @OptionalConvexFloat var lastSyncedAt: Double?
    @OptionalConvexFloat var lastPushedAt: Double?
    let manual: Bool?
    let teamId: String
    let name: String
    let userId: String
    let fullName: String
    let org: String
    let gitRemote: String
}

struct GithubGetBranchesByRepoItem: Decodable {
    let _id: ConvexId<ConvexTableBranches>
    @ConvexFloat var _creationTime: Double
    @OptionalConvexFloat var lastActivityAt: Double?
    let repoId: ConvexId<ConvexTableRepos>?
    let lastCommitSha: String?
    let lastKnownBaseSha: String?
    let lastKnownMergeCommitSha: String?
    let teamId: String
    let name: String
    let userId: String
    let repo: String
}

struct GithubListProviderConnectionsItemType: Decodable {
    @ConvexFloat var length: Double
}

struct GithubListProviderConnectionsItem: Decodable {
    let id: ConvexId<ConvexTableProviderConnections>
    @ConvexFloat var installationId: Double
    let accountLogin: String?
    let accountType: GithubListProviderConnectionsItemAccountTypeEnum?
    let type: GithubListProviderConnectionsItemType
    let isActive: Bool
}

struct GithubListUnassignedProviderConnectionsItem: Decodable {
    @ConvexFloat var installationId: Double
    let accountLogin: String?
    let accountType: GithubListUnassignedProviderConnectionsItemAccountTypeEnum?
    let isActive: Bool
}

struct GithubAssignProviderConnectionToTeamReturn: Decodable {
    let ok: Bool
}

struct GithubRemoveProviderConnectionReturn: Decodable {
    let ok: Bool
}

struct GithubBulkInsertReposArgsReposItem: ConvexEncodable {
    let provider: String?
    let name: String
    let fullName: String
    let org: String
    let gitRemote: String

    func convexEncode() throws -> String {
        var result: [String: ConvexEncodable?] = [:]
        if let value = provider { result["provider"] = value }
        result["name"] = name
        result["fullName"] = fullName
        result["org"] = org
        result["gitRemote"] = gitRemote
        return try result.convexEncode()
    }
}

struct GithubBulkInsertReposItemTableName: Decodable {
    @ConvexFloat var length: Double
}

struct GithubBulkInsertReposItem: Decodable {
    @ConvexFloat var length: Double
    let __tableName: GithubBulkInsertReposItemTableName
}

struct GithubBulkInsertBranchesItemTableName: Decodable {
    @ConvexFloat var length: Double
}

struct GithubBulkInsertBranchesItem: Decodable {
    @ConvexFloat var length: Double
    let __tableName: GithubBulkInsertBranchesItemTableName
}

struct GithubBulkUpsertBranchesWithActivityArgsBranchesItem: ConvexEncodable {
    let lastActivityAt: Double?
    let lastCommitSha: String?
    let lastKnownBaseSha: String?
    let lastKnownMergeCommitSha: String?
    let name: String

    func convexEncode() throws -> String {
        var result: [String: ConvexEncodable?] = [:]
        if let value = lastActivityAt { result["lastActivityAt"] = value }
        if let value = lastCommitSha { result["lastCommitSha"] = value }
        if let value = lastKnownBaseSha { result["lastKnownBaseSha"] = value }
        if let value = lastKnownMergeCommitSha { result["lastKnownMergeCommitSha"] = value }
        result["name"] = name
        return try result.convexEncode()
    }
}

struct GithubBulkUpsertBranchesWithActivityItemTableName: Decodable {
    @ConvexFloat var length: Double
}

struct GithubBulkUpsertBranchesWithActivityItem: Decodable {
    @ConvexFloat var length: Double
    let __tableName: GithubBulkUpsertBranchesWithActivityItemTableName
}

struct GithubReplaceAllReposArgsReposItem: ConvexEncodable {
    let provider: String?
    let name: String
    let fullName: String
    let org: String
    let gitRemote: String

    func convexEncode() throws -> String {
        var result: [String: ConvexEncodable?] = [:]
        if let value = provider { result["provider"] = value }
        result["name"] = name
        result["fullName"] = fullName
        result["org"] = org
        result["gitRemote"] = gitRemote
        return try result.convexEncode()
    }
}

struct GithubReplaceAllReposItemTableName: Decodable {
    @ConvexFloat var length: Double
}

struct GithubReplaceAllReposItem: Decodable {
    @ConvexFloat var length: Double
    let __tableName: GithubReplaceAllReposItemTableName
}

struct GithubAppMintInstallStateReturn: Decodable {
    let state: String
}

struct GithubCheckRunsGetCheckRunsForPrItemProvider: Decodable {
    @ConvexFloat var length: Double
}

struct GithubCheckRunsGetCheckRunsForPrItem: Decodable {
    let _id: ConvexId<ConvexTableGithubCheckRuns>
    @ConvexFloat var _creationTime: Double
    @OptionalConvexFloat var updatedAt: Double?
    let status: GithubCheckRunsGetCheckRunsForPrItemStatusEnum?
    @OptionalConvexFloat var completedAt: Double?
    @OptionalConvexFloat var startedAt: Double?
    @OptionalConvexFloat var repositoryId: Double?
    let htmlUrl: String?
    let conclusion: GithubCheckRunsGetCheckRunsForPrItemConclusionEnum?
    @OptionalConvexFloat var triggeringPrNumber: Double?
    let appName: String?
    let appSlug: String?
    let teamId: String
    let name: String
    let repoFullName: String
    let provider: GithubCheckRunsGetCheckRunsForPrItemProvider
    let headSha: String
    @ConvexFloat var installationId: Double
    @ConvexFloat var checkRunId: Double
}

struct GithubCommitStatusesGetCommitStatusesForPrItemProvider: Decodable {
    @ConvexFloat var length: Double
}

struct GithubCommitStatusesGetCommitStatusesForPrItem: Decodable {
    let _id: ConvexId<ConvexTableGithubCommitStatuses>
    @ConvexFloat var _creationTime: Double
    @OptionalConvexFloat var createdAt: Double?
    @OptionalConvexFloat var updatedAt: Double?
    let description: String?
    @OptionalConvexFloat var repositoryId: Double?
    @OptionalConvexFloat var triggeringPrNumber: Double?
    let creatorLogin: String?
    let targetUrl: String?
    let teamId: String
    let repoFullName: String
    let state: GithubCommitStatusesGetCommitStatusesForPrItemStateEnum
    let provider: GithubCommitStatusesGetCommitStatusesForPrItemProvider
    @ConvexFloat var installationId: Double
    let sha: String
    @ConvexFloat var statusId: Double
    let context: String
}

struct GithubDeploymentsGetDeploymentsForPrItemProvider: Decodable {
    @ConvexFloat var length: Double
}

struct GithubDeploymentsGetDeploymentsForPrItem: Decodable {
    let _id: ConvexId<ConvexTableGithubDeployments>
    @ConvexFloat var _creationTime: Double
    @OptionalConvexFloat var createdAt: Double?
    @OptionalConvexFloat var updatedAt: Double?
    let description: String?
    let state: GithubDeploymentsGetDeploymentsForPrItemStateEnum?
    @OptionalConvexFloat var repositoryId: Double?
    @OptionalConvexFloat var triggeringPrNumber: Double?
    let ref: String?
    let task: String?
    let environment: String?
    let creatorLogin: String?
    let statusDescription: String?
    let targetUrl: String?
    let environmentUrl: String?
    let logUrl: String?
    let teamId: String
    let repoFullName: String
    let provider: GithubDeploymentsGetDeploymentsForPrItemProvider
    @ConvexFloat var installationId: Double
    @ConvexFloat var deploymentId: Double
    let sha: String
}

struct GithubHttpAddManualRepoReturn: Decodable {
    let success: Bool
    let repoId: ConvexId<ConvexTableRepos>
    let fullName: String
}

struct GithubPrsListPullRequestsItemProvider: Decodable {
    @ConvexFloat var length: Double
}

struct GithubPrsListPullRequestsItem: Decodable {
    let _id: ConvexId<ConvexTablePullRequests>
    @ConvexFloat var _creationTime: Double
    @OptionalConvexFloat var createdAt: Double?
    @OptionalConvexFloat var updatedAt: Double?
    let draft: Bool?
    let merged: Bool?
    let headSha: String?
    let baseSha: String?
    let headRef: String?
    @OptionalConvexFloat var repositoryId: Double?
    @OptionalConvexFloat var providerPrId: Double?
    let authorLogin: String?
    @OptionalConvexFloat var authorId: Double?
    let htmlUrl: String?
    let baseRef: String?
    let mergeCommitSha: String?
    @OptionalConvexFloat var closedAt: Double?
    @OptionalConvexFloat var mergedAt: Double?
    @OptionalConvexFloat var commentsCount: Double?
    @OptionalConvexFloat var reviewCommentsCount: Double?
    @OptionalConvexFloat var commitsCount: Double?
    @OptionalConvexFloat var additions: Double?
    @OptionalConvexFloat var deletions: Double?
    @OptionalConvexFloat var changedFiles: Double?
    @ConvexFloat var number: Double
    let teamId: String
    let repoFullName: String
    let state: GithubPrsListPullRequestsItemStateEnum
    let provider: GithubPrsListPullRequestsItemProvider
    let title: String
    @ConvexFloat var installationId: Double
}

struct GithubPrsGetPullRequestReturnProvider: Decodable {
    @ConvexFloat var length: Double
}

struct GithubPrsGetPullRequestReturn: Decodable {
    let _id: ConvexId<ConvexTablePullRequests>
    @ConvexFloat var _creationTime: Double
    @OptionalConvexFloat var createdAt: Double?
    @OptionalConvexFloat var updatedAt: Double?
    let draft: Bool?
    let merged: Bool?
    let headSha: String?
    let baseSha: String?
    let headRef: String?
    @OptionalConvexFloat var repositoryId: Double?
    @OptionalConvexFloat var providerPrId: Double?
    let authorLogin: String?
    @OptionalConvexFloat var authorId: Double?
    let htmlUrl: String?
    let baseRef: String?
    let mergeCommitSha: String?
    @OptionalConvexFloat var closedAt: Double?
    @OptionalConvexFloat var mergedAt: Double?
    @OptionalConvexFloat var commentsCount: Double?
    @OptionalConvexFloat var reviewCommentsCount: Double?
    @OptionalConvexFloat var commitsCount: Double?
    @OptionalConvexFloat var additions: Double?
    @OptionalConvexFloat var deletions: Double?
    @OptionalConvexFloat var changedFiles: Double?
    @ConvexFloat var number: Double
    let teamId: String
    let repoFullName: String
    let state: GithubPrsGetPullRequestReturnStateEnum
    let provider: GithubPrsGetPullRequestReturnProvider
    let title: String
    @ConvexFloat var installationId: Double
}

struct GithubPrsUpsertFromServerArgsRecord: ConvexEncodable {
    let createdAt: Double?
    let updatedAt: Double?
    let draft: Bool?
    let merged: Bool?
    let headSha: String?
    let baseSha: String?
    let headRef: String?
    let repositoryId: Double?
    let providerPrId: Double?
    let authorLogin: String?
    let authorId: Double?
    let htmlUrl: String?
    let baseRef: String?
    let mergeCommitSha: String?
    let closedAt: Double?
    let mergedAt: Double?
    let commentsCount: Double?
    let reviewCommentsCount: Double?
    let commitsCount: Double?
    let additions: Double?
    let deletions: Double?
    let changedFiles: Double?
    let state: GithubPrsUpsertFromServerArgsRecordStateEnum
    let title: String

    func convexEncode() throws -> String {
        var result: [String: ConvexEncodable?] = [:]
        if let value = createdAt { result["createdAt"] = value }
        if let value = updatedAt { result["updatedAt"] = value }
        if let value = draft { result["draft"] = value }
        if let value = merged { result["merged"] = value }
        if let value = headSha { result["headSha"] = value }
        if let value = baseSha { result["baseSha"] = value }
        if let value = headRef { result["headRef"] = value }
        if let value = repositoryId { result["repositoryId"] = value }
        if let value = providerPrId { result["providerPrId"] = value }
        if let value = authorLogin { result["authorLogin"] = value }
        if let value = authorId { result["authorId"] = value }
        if let value = htmlUrl { result["htmlUrl"] = value }
        if let value = baseRef { result["baseRef"] = value }
        if let value = mergeCommitSha { result["mergeCommitSha"] = value }
        if let value = closedAt { result["closedAt"] = value }
        if let value = mergedAt { result["mergedAt"] = value }
        if let value = commentsCount { result["commentsCount"] = value }
        if let value = reviewCommentsCount { result["reviewCommentsCount"] = value }
        if let value = commitsCount { result["commitsCount"] = value }
        if let value = additions { result["additions"] = value }
        if let value = deletions { result["deletions"] = value }
        if let value = changedFiles { result["changedFiles"] = value }
        result["state"] = state
        result["title"] = title
        return try result.convexEncode()
    }
}

struct GithubPrsUpsertFromServerReturnTableName: Decodable {
    @ConvexFloat var length: Double
}

struct GithubPrsUpsertFromServerReturn: Decodable {
    @ConvexFloat var length: Double
    let __tableName: GithubPrsUpsertFromServerReturnTableName
}

struct GithubWorkflowsGetWorkflowRunsItemProvider: Decodable {
    @ConvexFloat var length: Double
}

struct GithubWorkflowsGetWorkflowRunsItem: Decodable {
    let _id: ConvexId<ConvexTableGithubWorkflowRuns>
    @ConvexFloat var _creationTime: Double
    let name: String?
    @OptionalConvexFloat var createdAt: Double?
    @OptionalConvexFloat var updatedAt: Double?
    let status: GithubWorkflowsGetWorkflowRunsItemStatusEnum?
    let headSha: String?
    @OptionalConvexFloat var repositoryId: Double?
    let htmlUrl: String?
    let conclusion: GithubWorkflowsGetWorkflowRunsItemConclusionEnum?
    let headBranch: String?
    @OptionalConvexFloat var runStartedAt: Double?
    @OptionalConvexFloat var runCompletedAt: Double?
    @OptionalConvexFloat var runDuration: Double?
    let actorLogin: String?
    @OptionalConvexFloat var actorId: Double?
    @OptionalConvexFloat var triggeringPrNumber: Double?
    let teamId: String
    let repoFullName: String
    let provider: GithubWorkflowsGetWorkflowRunsItemProvider
    @ConvexFloat var runId: Double
    @ConvexFloat var installationId: Double
    @ConvexFloat var runNumber: Double
    @ConvexFloat var workflowId: Double
    let workflowName: String
    let event: String
}

struct GithubWorkflowsGetWorkflowRunByIdReturnProvider: Decodable {
    @ConvexFloat var length: Double
}

struct GithubWorkflowsGetWorkflowRunByIdReturn: Decodable {
    let _id: ConvexId<ConvexTableGithubWorkflowRuns>
    @ConvexFloat var _creationTime: Double
    let name: String?
    @OptionalConvexFloat var createdAt: Double?
    @OptionalConvexFloat var updatedAt: Double?
    let status: GithubWorkflowsGetWorkflowRunByIdReturnStatusEnum?
    let headSha: String?
    @OptionalConvexFloat var repositoryId: Double?
    let htmlUrl: String?
    let conclusion: GithubWorkflowsGetWorkflowRunByIdReturnConclusionEnum?
    let headBranch: String?
    @OptionalConvexFloat var runStartedAt: Double?
    @OptionalConvexFloat var runCompletedAt: Double?
    @OptionalConvexFloat var runDuration: Double?
    let actorLogin: String?
    @OptionalConvexFloat var actorId: Double?
    @OptionalConvexFloat var triggeringPrNumber: Double?
    let teamId: String
    let repoFullName: String
    let provider: GithubWorkflowsGetWorkflowRunByIdReturnProvider
    @ConvexFloat var runId: Double
    @ConvexFloat var installationId: Double
    @ConvexFloat var runNumber: Double
    @ConvexFloat var workflowId: Double
    let workflowName: String
    let event: String
}

struct GithubWorkflowsGetWorkflowRunsForPrItemProvider: Decodable {
    @ConvexFloat var length: Double
}

struct GithubWorkflowsGetWorkflowRunsForPrItem: Decodable {
    let _id: ConvexId<ConvexTableGithubWorkflowRuns>
    @ConvexFloat var _creationTime: Double
    let name: String?
    @OptionalConvexFloat var createdAt: Double?
    @OptionalConvexFloat var updatedAt: Double?
    let status: GithubWorkflowsGetWorkflowRunsForPrItemStatusEnum?
    let headSha: String?
    @OptionalConvexFloat var repositoryId: Double?
    let htmlUrl: String?
    let conclusion: GithubWorkflowsGetWorkflowRunsForPrItemConclusionEnum?
    let headBranch: String?
    @OptionalConvexFloat var runStartedAt: Double?
    @OptionalConvexFloat var runCompletedAt: Double?
    @OptionalConvexFloat var runDuration: Double?
    let actorLogin: String?
    @OptionalConvexFloat var actorId: Double?
    @OptionalConvexFloat var triggeringPrNumber: Double?
    let teamId: String
    let repoFullName: String
    let provider: GithubWorkflowsGetWorkflowRunsForPrItemProvider
    @ConvexFloat var runId: Double
    @ConvexFloat var installationId: Double
    @ConvexFloat var runNumber: Double
    @ConvexFloat var workflowId: Double
    let workflowName: String
    let event: String
}

struct HostScreenshotCollectorGetLatestReleaseUrlReturn: Decodable {
    let version: String
    let commitSha: String
    let url: String?
    let releaseUrl: String?
    @ConvexFloat var createdAt: Double
}

struct HostScreenshotCollectorListReleasesItem: Decodable {
    let version: String
    let commitSha: String
    let isLatest: Bool
    let url: String?
    let releaseUrl: String?
    @ConvexFloat var createdAt: Double
}

struct HostScreenshotCollectorActionsSyncReleaseReturn: Decodable {
    let releaseId: ConvexId<ConvexTableHostScreenshotCollectorReleases>
    let storageId: ConvexId<ConvexTableStorage>
}

struct LocalWorkspacesNextSequenceReturn: Decodable {
    @ConvexFloat var sequence: Double
    let suffix: String
}

struct LocalWorkspacesReserveReturn: Decodable {
    @ConvexFloat var sequence: Double
    let suffix: String
    let workspaceName: String
    let descriptor: String
    let taskId: ConvexId<ConvexTableTasks>
    let taskRunId: ConvexId<ConvexTableTaskRuns>
}

struct MorphInstancesGetActivityReturn: Decodable {
    let _id: ConvexId<ConvexTableMorphInstanceActivity>
    @ConvexFloat var _creationTime: Double
    @OptionalConvexFloat var stoppedAt: Double?
    @OptionalConvexFloat var lastPausedAt: Double?
    @OptionalConvexFloat var lastResumedAt: Double?
    let instanceId: String
}

struct PreviewConfigsListByTeamItemRepoProvider: Decodable {
    @ConvexFloat var length: Double
}

struct PreviewConfigsListByTeamItem: Decodable {
    let _id: ConvexId<ConvexTablePreviewConfigs>
    @ConvexFloat var _creationTime: Double
    let environmentId: ConvexId<ConvexTableEnvironments>?
    let status: PreviewConfigsListByTeamItemStatusEnum?
    let createdByUserId: String?
    let repoProvider: PreviewConfigsListByTeamItemRepoProvider?
    @OptionalConvexFloat var repoInstallationId: Double?
    let repoDefaultBranch: String?
    @OptionalConvexFloat var lastRunAt: Double?
    let teamId: String
    @ConvexFloat var createdAt: Double
    @ConvexFloat var updatedAt: Double
    let repoFullName: String
}

struct PreviewConfigsGetReturnRepoProvider: Decodable {
    @ConvexFloat var length: Double
}

struct PreviewConfigsGetReturn: Decodable {
    let _id: ConvexId<ConvexTablePreviewConfigs>
    @ConvexFloat var _creationTime: Double
    let environmentId: ConvexId<ConvexTableEnvironments>?
    let status: PreviewConfigsGetReturnStatusEnum?
    let createdByUserId: String?
    let repoProvider: PreviewConfigsGetReturnRepoProvider?
    @OptionalConvexFloat var repoInstallationId: Double?
    let repoDefaultBranch: String?
    @OptionalConvexFloat var lastRunAt: Double?
    let teamId: String
    @ConvexFloat var createdAt: Double
    @ConvexFloat var updatedAt: Double
    let repoFullName: String
}

struct PreviewConfigsGetByRepoReturnRepoProvider: Decodable {
    @ConvexFloat var length: Double
}

struct PreviewConfigsGetByRepoReturn: Decodable {
    let _id: ConvexId<ConvexTablePreviewConfigs>
    @ConvexFloat var _creationTime: Double
    let environmentId: ConvexId<ConvexTableEnvironments>?
    let status: PreviewConfigsGetByRepoReturnStatusEnum?
    let createdByUserId: String?
    let repoProvider: PreviewConfigsGetByRepoReturnRepoProvider?
    @OptionalConvexFloat var repoInstallationId: Double?
    let repoDefaultBranch: String?
    @OptionalConvexFloat var lastRunAt: Double?
    let teamId: String
    @ConvexFloat var createdAt: Double
    @ConvexFloat var updatedAt: Double
    let repoFullName: String
}

struct PreviewConfigsRemoveReturn: Decodable {
    let id: ConvexId<ConvexTablePreviewConfigs>
}

struct PreviewConfigsUpsertReturnTableName: Decodable {
    @ConvexFloat var length: Double
}

struct PreviewConfigsUpsertReturn: Decodable {
    @ConvexFloat var length: Double
    let __tableName: PreviewConfigsUpsertReturnTableName
}

struct PreviewRunsListByConfigItem: Decodable {
    let _id: ConvexId<ConvexTablePreviewRuns>
    @ConvexFloat var _creationTime: Double
    @OptionalConvexFloat var completedAt: Double?
    @OptionalConvexFloat var startedAt: Double?
    let taskRunId: ConvexId<ConvexTableTaskRuns>?
    @OptionalConvexFloat var repoInstallationId: Double?
    let prTitle: String?
    let prDescription: String?
    let baseSha: String?
    let headRef: String?
    let headRepoFullName: String?
    let headRepoCloneUrl: String?
    let supersededBy: ConvexId<ConvexTablePreviewRuns>?
    let stateReason: String?
    @OptionalConvexFloat var dispatchedAt: Double?
    let screenshotSetId: ConvexId<ConvexTableTaskRunScreenshotSets>?
    let githubCommentUrl: String?
    @OptionalConvexFloat var githubCommentId: Double?
    let teamId: String
    @ConvexFloat var createdAt: Double
    @ConvexFloat var updatedAt: Double
    let status: PreviewRunsListByConfigItemStatusEnum
    let repoFullName: String
    @ConvexFloat var prNumber: Double
    let previewConfigId: ConvexId<ConvexTablePreviewConfigs>
    let prUrl: String
    let headSha: String
}

struct PreviewRunsListByTeamItem: Decodable {
    let _id: ConvexId<ConvexTablePreviewRuns>
    @ConvexFloat var _creationTime: Double
    @OptionalConvexFloat var completedAt: Double?
    @OptionalConvexFloat var startedAt: Double?
    let taskRunId: ConvexId<ConvexTableTaskRuns>?
    @OptionalConvexFloat var repoInstallationId: Double?
    let prTitle: String?
    let prDescription: String?
    let baseSha: String?
    let headRef: String?
    let headRepoFullName: String?
    let headRepoCloneUrl: String?
    let supersededBy: ConvexId<ConvexTablePreviewRuns>?
    let stateReason: String?
    @OptionalConvexFloat var dispatchedAt: Double?
    let screenshotSetId: ConvexId<ConvexTableTaskRunScreenshotSets>?
    let githubCommentUrl: String?
    @OptionalConvexFloat var githubCommentId: Double?
    let teamId: String
    @ConvexFloat var createdAt: Double
    @ConvexFloat var updatedAt: Double
    let status: PreviewRunsListByTeamItemStatusEnum
    let repoFullName: String
    @ConvexFloat var prNumber: Double
    let previewConfigId: ConvexId<ConvexTablePreviewConfigs>
    let prUrl: String
    let headSha: String
    let configRepoFullName: String?
    let taskId: ConvexId<ConvexTableTasks>?
}

struct PreviewRunsListByTeamPaginatedArgsPaginationOpts: ConvexEncodable {
    let id: Double?
    let endCursor: String?
    let maximumRowsRead: Double?
    let maximumBytesRead: Double?
    let numItems: Double
    let cursor: String?

    func convexEncode() throws -> String {
        var result: [String: ConvexEncodable?] = [:]
        if let value = id { result["id"] = value }
        if let value = endCursor { result["endCursor"] = value }
        if let value = maximumRowsRead { result["maximumRowsRead"] = value }
        if let value = maximumBytesRead { result["maximumBytesRead"] = value }
        result["numItems"] = numItems
        if let value = cursor { result["cursor"] = value } else { result["cursor"] = ConvexNull() }
        return try result.convexEncode()
    }
}

struct PreviewRunsListByTeamPaginatedReturnPageItem: Decodable {
    let _id: ConvexId<ConvexTablePreviewRuns>
    @ConvexFloat var _creationTime: Double
    @OptionalConvexFloat var completedAt: Double?
    @OptionalConvexFloat var startedAt: Double?
    let taskRunId: ConvexId<ConvexTableTaskRuns>?
    @OptionalConvexFloat var repoInstallationId: Double?
    let prTitle: String?
    let prDescription: String?
    let baseSha: String?
    let headRef: String?
    let headRepoFullName: String?
    let headRepoCloneUrl: String?
    let supersededBy: ConvexId<ConvexTablePreviewRuns>?
    let stateReason: String?
    @OptionalConvexFloat var dispatchedAt: Double?
    let screenshotSetId: ConvexId<ConvexTableTaskRunScreenshotSets>?
    let githubCommentUrl: String?
    @OptionalConvexFloat var githubCommentId: Double?
    let teamId: String
    @ConvexFloat var createdAt: Double
    @ConvexFloat var updatedAt: Double
    let status: PreviewRunsListByTeamPaginatedReturnPageItemStatusEnum
    let repoFullName: String
    @ConvexFloat var prNumber: Double
    let previewConfigId: ConvexId<ConvexTablePreviewConfigs>
    let prUrl: String
    let headSha: String
    let configRepoFullName: String?
    let taskId: ConvexId<ConvexTableTasks>?
}

struct PreviewRunsListByTeamPaginatedReturn: Decodable {
    let page: [PreviewRunsListByTeamPaginatedReturnPageItem]
    let isDone: Bool
    let continueCursor: String
    let splitCursor: String?
    let pageStatus: PreviewRunsListByTeamPaginatedReturnPageStatusEnum?
}

struct PreviewRunsCreateManualReturn: Decodable {
    let previewRunId: ConvexId<ConvexTablePreviewRuns>
    let reused: Bool
}

struct PreviewScreenshotsUploadAndCommentArgsImagesItem: ConvexEncodable {
    let description: String?
    let fileName: String?
    let width: Double?
    let height: Double?
    let storageId: String
    let commitSha: String
    let mimeType: String

    func convexEncode() throws -> String {
        var result: [String: ConvexEncodable?] = [:]
        if let value = description { result["description"] = value }
        if let value = fileName { result["fileName"] = value }
        if let value = width { result["width"] = value }
        if let value = height { result["height"] = value }
        result["storageId"] = storageId
        result["commitSha"] = commitSha
        result["mimeType"] = mimeType
        return try result.convexEncode()
    }
}

struct PreviewScreenshotsUploadAndCommentArgsVideosItem: ConvexEncodable {
    let description: String?
    let fileName: String?
    let storageId: String
    let mimeType: String

    func convexEncode() throws -> String {
        var result: [String: ConvexEncodable?] = [:]
        if let value = description { result["description"] = value }
        if let value = fileName { result["fileName"] = value }
        result["storageId"] = storageId
        result["mimeType"] = mimeType
        return try result.convexEncode()
    }
}

struct PreviewScreenshotsUploadAndCommentReturn: Decodable {
    let ok: Bool
    let screenshotSetId: String?
    let githubCommentUrl: String?
}

struct PreviewTestJobsCreateTestRunArgsPrMetadata: ConvexEncodable {
    let prDescription: String?
    let baseSha: String?
    let headRef: String?
    let headRepoFullName: String?
    let headRepoCloneUrl: String?
    let prTitle: String
    let headSha: String

    func convexEncode() throws -> String {
        var result: [String: ConvexEncodable?] = [:]
        if let value = prDescription { result["prDescription"] = value }
        if let value = baseSha { result["baseSha"] = value }
        if let value = headRef { result["headRef"] = value }
        if let value = headRepoFullName { result["headRepoFullName"] = value }
        if let value = headRepoCloneUrl { result["headRepoCloneUrl"] = value }
        result["prTitle"] = prTitle
        result["headSha"] = headSha
        return try result.convexEncode()
    }
}

struct PreviewTestJobsCreateTestRunReturn: Decodable {
    let previewRunId: ConvexId<ConvexTablePreviewRuns>
    @ConvexFloat var prNumber: Double
    let repoFullName: String
}

struct PreviewTestJobsDispatchTestJobReturn: Decodable {
    let dispatched: Bool
}

struct PreviewTestJobsListTestRunsItemScreenshotSetImagesItem: Decodable {
    let storageId: String
    let mimeType: String
    let fileName: String?
    let description: String?
    let url: String?
}

struct PreviewTestJobsListTestRunsItemScreenshotSetVideosItem: Decodable {
    let storageId: String
    let mimeType: String
    let fileName: String?
    let description: String?
    let url: String?
}

struct PreviewTestJobsListTestRunsItemScreenshotSet: Decodable {
    let _id: ConvexId<ConvexTableTaskRunScreenshotSets>
    let status: PreviewTestJobsListTestRunsItemScreenshotSetStatusEnum
    let hasUiChanges: Bool?
    @ConvexFloat var capturedAt: Double
    let error: String?
    let images: [PreviewTestJobsListTestRunsItemScreenshotSetImagesItem]
    let videos: [PreviewTestJobsListTestRunsItemScreenshotSetVideosItem]
}

struct PreviewTestJobsListTestRunsItem: Decodable {
    let _id: ConvexId<ConvexTablePreviewRuns>
    @ConvexFloat var prNumber: Double
    let prUrl: String
    let prTitle: String?
    let repoFullName: String
    let headSha: String
    let status: PreviewTestJobsListTestRunsItemStatusEnum
    let stateReason: String?
    let taskId: ConvexId<ConvexTableTasks>?
    let taskRunId: ConvexId<ConvexTableTaskRuns>?
    @ConvexFloat var createdAt: Double
    @ConvexFloat var updatedAt: Double
    @OptionalConvexFloat var dispatchedAt: Double?
    @OptionalConvexFloat var startedAt: Double?
    @OptionalConvexFloat var completedAt: Double?
    let configRepoFullName: String?
    let screenshotSet: PreviewTestJobsListTestRunsItemScreenshotSet?
}

struct PreviewTestJobsGetTestRunDetailsReturnScreenshotSetImagesItem: Decodable {
    let storageId: String
    let mimeType: String
    let fileName: String?
    let description: String?
    let url: String?
}

struct PreviewTestJobsGetTestRunDetailsReturnScreenshotSetVideosItem: Decodable {
    let storageId: String
    let mimeType: String
    let fileName: String?
    let description: String?
    let url: String?
}

struct PreviewTestJobsGetTestRunDetailsReturnScreenshotSet: Decodable {
    let _id: ConvexId<ConvexTableTaskRunScreenshotSets>
    let status: PreviewTestJobsGetTestRunDetailsReturnScreenshotSetStatusEnum
    let hasUiChanges: Bool?
    @ConvexFloat var capturedAt: Double
    let error: String?
    let images: [PreviewTestJobsGetTestRunDetailsReturnScreenshotSetImagesItem]
    let videos: [PreviewTestJobsGetTestRunDetailsReturnScreenshotSetVideosItem]
}

struct PreviewTestJobsGetTestRunDetailsReturn: Decodable {
    let _id: ConvexId<ConvexTablePreviewRuns>
    @ConvexFloat var prNumber: Double
    let prUrl: String
    let prTitle: String?
    let prDescription: String?
    let repoFullName: String
    let headSha: String
    let baseSha: String?
    let headRef: String?
    let status: PreviewTestJobsGetTestRunDetailsReturnStatusEnum
    let stateReason: String?
    let taskRunId: ConvexId<ConvexTableTaskRuns>?
    let taskId: ConvexId<ConvexTableTasks>?
    @ConvexFloat var createdAt: Double
    @ConvexFloat var updatedAt: Double
    @OptionalConvexFloat var dispatchedAt: Double?
    @OptionalConvexFloat var startedAt: Double?
    @OptionalConvexFloat var completedAt: Double?
    let configRepoFullName: String?
    let environmentId: ConvexId<ConvexTableEnvironments>?
    let screenshotSet: PreviewTestJobsGetTestRunDetailsReturnScreenshotSet?
}

struct PreviewTestJobsCheckRepoAccessReturn: Decodable {
    let hasAccess: Bool
    let hasConfig: Bool
    let hasActiveInstallation: Bool
    let repoFullName: String?
    let errorCode: PreviewTestJobsCheckRepoAccessReturnErrorCodeEnum?
    let errorMessage: String?
    let suggestedAction: String?
}

struct PreviewTestJobsRetryTestJobReturn: Decodable {
    let newPreviewRunId: ConvexId<ConvexTablePreviewRuns>
    let dispatched: Bool
}

struct PreviewTestJobsDeleteTestRunReturn: Decodable {
    let deleted: Bool
}

struct StackUpsertUserPublicArgsOauthProvidersItem: ConvexEncodable {
    let email: String?
    let id: String
    let accountId: String

    func convexEncode() throws -> String {
        var result: [String: ConvexEncodable?] = [:]
        if let value = email { result["email"] = value }
        result["id"] = id
        result["accountId"] = accountId
        return try result.convexEncode()
    }
}

struct StorageGetUrlsItem: Decodable {
    let storageId: ConvexId<ConvexTableStorage>
    let url: String
}

struct TaskCommentsListByTaskItem: Decodable {
    let _id: ConvexId<ConvexTableTaskComments>
    @ConvexFloat var _creationTime: Double
    let teamId: String
    @ConvexFloat var createdAt: Double
    @ConvexFloat var updatedAt: Double
    let userId: String
    let taskId: ConvexId<ConvexTableTasks>
    let content: String
}

struct TaskCommentsCreateForTaskReturnTableName: Decodable {
    @ConvexFloat var length: Double
}

struct TaskCommentsCreateForTaskReturn: Decodable {
    @ConvexFloat var length: Double
    let __tableName: TaskCommentsCreateForTaskReturnTableName
}

struct TaskCommentsCreateSystemForTaskReturnTableName: Decodable {
    @ConvexFloat var length: Double
}

struct TaskCommentsCreateSystemForTaskReturn: Decodable {
    @ConvexFloat var length: Double
    let __tableName: TaskCommentsCreateSystemForTaskReturnTableName
}

struct TaskCommentsLatestSystemByTaskReturn: Decodable {
    let _id: ConvexId<ConvexTableTaskComments>
    @ConvexFloat var _creationTime: Double
    let teamId: String
    @ConvexFloat var createdAt: Double
    @ConvexFloat var updatedAt: Double
    let userId: String
    let taskId: ConvexId<ConvexTableTasks>
    let content: String
}

struct TaskNotificationsListItemTaskImagesItem: Decodable {
    let fileName: String?
    let storageId: ConvexId<ConvexTableStorage>
    let altText: String
}

struct TaskNotificationsListItemTask: Decodable {
    let _id: ConvexId<ConvexTableTasks>
    @ConvexFloat var _creationTime: Double
    @OptionalConvexFloat var createdAt: Double?
    @OptionalConvexFloat var updatedAt: Double?
    let isArchived: Bool?
    let pinned: Bool?
    let isPreview: Bool?
    let isLocalWorkspace: Bool?
    let isCloudWorkspace: Bool?
    let linkedFromCloudTaskRunId: ConvexId<ConvexTableTaskRuns>?
    let description: String?
    let pullRequestTitle: String?
    let pullRequestDescription: String?
    let projectFullName: String?
    let baseBranch: String?
    let worktreePath: String?
    let generatedBranchName: String?
    @OptionalConvexFloat var lastActivityAt: Double?
    let environmentId: ConvexId<ConvexTableEnvironments>?
    let crownEvaluationStatus: TaskNotificationsListItemTaskCrownEvaluationStatusEnum?
    let crownEvaluationError: String?
    let mergeStatus: TaskNotificationsListItemTaskMergeStatusEnum?
    let images: [TaskNotificationsListItemTaskImagesItem]?
    let screenshotStatus: TaskNotificationsListItemTaskScreenshotStatusEnum?
    let screenshotRunId: ConvexId<ConvexTableTaskRuns>?
    let screenshotRequestId: String?
    @OptionalConvexFloat var screenshotRequestedAt: Double?
    @OptionalConvexFloat var screenshotCompletedAt: Double?
    let screenshotError: String?
    let screenshotStorageId: ConvexId<ConvexTableStorage>?
    let screenshotMimeType: String?
    let screenshotFileName: String?
    let screenshotCommitSha: String?
    let latestScreenshotSetId: ConvexId<ConvexTableTaskRunScreenshotSets>?
    let teamId: String
    let userId: String
    let text: String
    let isCompleted: Bool
}

struct TaskNotificationsListItemTaskRunEnvironmentError: Decodable {
    let devError: String?
    let maintenanceError: String?
}

struct TaskNotificationsListItemTaskRunPullRequestsItem: Decodable {
    @OptionalConvexFloat var number: Double?
    let url: String?
    let isDraft: Bool?
    let repoFullName: String
    let state: TaskNotificationsListItemTaskRunPullRequestsItemStateEnum
}

struct TaskNotificationsListItemTaskRunClaimsItemEvidence: Decodable {
    @OptionalConvexFloat var screenshotIndex: Double?
    let filePath: String?
    @OptionalConvexFloat var startLine: Double?
    @OptionalConvexFloat var endLine: Double?
    let type: String
}

struct TaskNotificationsListItemTaskRunClaimsItem: Decodable {
    let claim: String
    let evidence: TaskNotificationsListItemTaskRunClaimsItemEvidence
    @ConvexFloat var timestamp: Double
}

struct TaskNotificationsListItemTaskRunVscodePorts: Decodable {
    let `extension`: String?
    let proxy: String?
    let vnc: String?
    let vscode: String
    let worker: String
}

struct TaskNotificationsListItemTaskRunVscode: Decodable {
    let url: String?
    let containerName: String?
    let statusMessage: String?
    let ports: TaskNotificationsListItemTaskRunVscodePorts?
    let workspaceUrl: String?
    @OptionalConvexFloat var startedAt: Double?
    @OptionalConvexFloat var stoppedAt: Double?
    @OptionalConvexFloat var lastAccessedAt: Double?
    let keepAlive: Bool?
    @OptionalConvexFloat var scheduledStopAt: Double?
    let status: TaskNotificationsListItemTaskRunVscodeStatusEnum
    let provider: TaskNotificationsListItemTaskRunVscodeProviderEnum
}

struct TaskNotificationsListItemTaskRunNetworkingItem: Decodable {
    let status: TaskNotificationsListItemTaskRunNetworkingItemStatusEnum
    let url: String
    @ConvexFloat var port: Double
}

struct TaskNotificationsListItemTaskRunCustomPreviewsItem: Decodable {
    @ConvexFloat var createdAt: Double
    let url: String
}

struct TaskNotificationsListItemTaskRun: Decodable {
    let _id: ConvexId<ConvexTableTaskRuns>
    @ConvexFloat var _creationTime: Double
    let isArchived: Bool?
    let isLocalWorkspace: Bool?
    let isCloudWorkspace: Bool?
    let worktreePath: String?
    let environmentId: ConvexId<ConvexTableEnvironments>?
    let screenshotStorageId: ConvexId<ConvexTableStorage>?
    let screenshotMimeType: String?
    let screenshotFileName: String?
    let screenshotCommitSha: String?
    let latestScreenshotSetId: ConvexId<ConvexTableTaskRunScreenshotSets>?
    let parentRunId: ConvexId<ConvexTableTaskRuns>?
    let agentName: String?
    let summary: String?
    let isPreviewJob: Bool?
    let log: String?
    let newBranch: String?
    @OptionalConvexFloat var completedAt: Double?
    @OptionalConvexFloat var exitCode: Double?
    let environmentError: TaskNotificationsListItemTaskRunEnvironmentError?
    let errorMessage: String?
    let isCrowned: Bool?
    let crownReason: String?
    let pullRequestUrl: String?
    let pullRequestIsDraft: Bool?
    let pullRequestState: TaskNotificationsListItemTaskRunPullRequestStateEnum?
    @OptionalConvexFloat var pullRequestNumber: Double?
    let pullRequests: [TaskNotificationsListItemTaskRunPullRequestsItem]?
    @OptionalConvexFloat var diffsLastUpdated: Double?
    @OptionalConvexFloat var screenshotCapturedAt: Double?
    let claims: [TaskNotificationsListItemTaskRunClaimsItem]?
    @OptionalConvexFloat var claimsGeneratedAt: Double?
    let vscode: TaskNotificationsListItemTaskRunVscode?
    let networking: [TaskNotificationsListItemTaskRunNetworkingItem]?
    let customPreviews: [TaskNotificationsListItemTaskRunCustomPreviewsItem]?
    let teamId: String
    @ConvexFloat var createdAt: Double
    @ConvexFloat var updatedAt: Double
    let userId: String
    let taskId: ConvexId<ConvexTableTasks>
    let prompt: String
    let status: TaskNotificationsListItemTaskRunStatusEnum
}

struct TaskNotificationsListItem: Decodable {
    let task: TaskNotificationsListItemTask?
    let taskRun: TaskNotificationsListItemTaskRun?
    let isUnread: Bool
    let _id: ConvexId<ConvexTableTaskNotifications>
    @ConvexFloat var _creationTime: Double
    let taskRunId: ConvexId<ConvexTableTaskRuns>?
    let message: String?
    @OptionalConvexFloat var readAt: Double?
    let teamId: String
    @ConvexFloat var createdAt: Double
    let type: TaskNotificationsListItemTypeEnum
    let userId: String
    let taskId: ConvexId<ConvexTableTasks>
}

struct TaskNotificationsGetTasksWithUnreadItem: Decodable {
    let taskId: ConvexId<ConvexTableTasks>
    @ConvexFloat var unreadCount: Double
    @ConvexFloat var latestNotificationAt: Double
}

struct TaskRunLogChunksGetChunksItem: Decodable {
    let _id: ConvexId<ConvexTableTaskRunLogChunks>
    @ConvexFloat var _creationTime: Double
    let teamId: String
    let userId: String
    let taskRunId: ConvexId<ConvexTableTaskRuns>
    let content: String
}

struct TaskRunsCreateReturn: Decodable {
    let taskRunId: ConvexId<ConvexTableTaskRuns>
    let jwt: String
}

struct TaskRunsGetByTaskArgsTaskId: ConvexEncodable {
    let length: Double

    func convexEncode() throws -> String {
        var result: [String: ConvexEncodable?] = [:]
        result["length"] = length
        return try result.convexEncode()
    }
}

struct TaskRunsGetByTaskItemEnvironmentError: Decodable {
    let devError: String?
    let maintenanceError: String?
}

struct TaskRunsGetByTaskItemPullRequestsItem: Decodable {
    @OptionalConvexFloat var number: Double?
    let url: String?
    let isDraft: Bool?
    let repoFullName: String
    let state: TaskRunsGetByTaskItemPullRequestsItemStateEnum
}

struct TaskRunsGetByTaskItemClaimsItemEvidence: Decodable {
    @OptionalConvexFloat var screenshotIndex: Double?
    let filePath: String?
    @OptionalConvexFloat var startLine: Double?
    @OptionalConvexFloat var endLine: Double?
    let type: String
}

struct TaskRunsGetByTaskItemClaimsItem: Decodable {
    let claim: String
    let evidence: TaskRunsGetByTaskItemClaimsItemEvidence
    @ConvexFloat var timestamp: Double
}

struct TaskRunsGetByTaskItemVscodePorts: Decodable {
    let `extension`: String?
    let proxy: String?
    let vnc: String?
    let vscode: String
    let worker: String
}

struct TaskRunsGetByTaskItemVscode: Decodable {
    let url: String?
    let containerName: String?
    let statusMessage: String?
    let ports: TaskRunsGetByTaskItemVscodePorts?
    let workspaceUrl: String?
    @OptionalConvexFloat var startedAt: Double?
    @OptionalConvexFloat var stoppedAt: Double?
    @OptionalConvexFloat var lastAccessedAt: Double?
    let keepAlive: Bool?
    @OptionalConvexFloat var scheduledStopAt: Double?
    let status: TaskRunsGetByTaskItemVscodeStatusEnum
    let provider: TaskRunsGetByTaskItemVscodeProviderEnum
}

struct TaskRunsGetByTaskItemNetworkingItem: Decodable {
    let status: TaskRunsGetByTaskItemNetworkingItemStatusEnum
    let url: String
    @ConvexFloat var port: Double
}

struct TaskRunsGetByTaskItemCustomPreviewsItem: Decodable {
    @ConvexFloat var createdAt: Double
    let url: String
}

struct TaskRunsGetByTaskItemEnvironment: Decodable {
    let name: String
    let selectedRepos: [String]?
    let _id: ConvexId<ConvexTableEnvironments>
}

struct TaskRunsGetByTaskItem: Decodable {
    let _id: ConvexId<ConvexTableTaskRuns>
    @ConvexFloat var _creationTime: Double
    let isArchived: Bool?
    let isLocalWorkspace: Bool?
    let isCloudWorkspace: Bool?
    let worktreePath: String?
    let environmentId: ConvexId<ConvexTableEnvironments>?
    let screenshotStorageId: ConvexId<ConvexTableStorage>?
    let screenshotMimeType: String?
    let screenshotFileName: String?
    let screenshotCommitSha: String?
    let latestScreenshotSetId: ConvexId<ConvexTableTaskRunScreenshotSets>?
    let parentRunId: ConvexId<ConvexTableTaskRuns>?
    let agentName: String?
    let summary: String?
    let isPreviewJob: Bool?
    let log: String?
    let newBranch: String?
    @OptionalConvexFloat var completedAt: Double?
    @OptionalConvexFloat var exitCode: Double?
    let environmentError: TaskRunsGetByTaskItemEnvironmentError?
    let errorMessage: String?
    let isCrowned: Bool?
    let crownReason: String?
    let pullRequestUrl: String?
    let pullRequestIsDraft: Bool?
    let pullRequestState: TaskRunsGetByTaskItemPullRequestStateEnum?
    @OptionalConvexFloat var pullRequestNumber: Double?
    let pullRequests: [TaskRunsGetByTaskItemPullRequestsItem]?
    @OptionalConvexFloat var diffsLastUpdated: Double?
    @OptionalConvexFloat var screenshotCapturedAt: Double?
    let claims: [TaskRunsGetByTaskItemClaimsItem]?
    @OptionalConvexFloat var claimsGeneratedAt: Double?
    let vscode: TaskRunsGetByTaskItemVscode?
    let networking: [TaskRunsGetByTaskItemNetworkingItem]?
    let customPreviews: [TaskRunsGetByTaskItemCustomPreviewsItem]?
    let teamId: String
    @ConvexFloat var createdAt: Double
    @ConvexFloat var updatedAt: Double
    let userId: String
    let taskId: ConvexId<ConvexTableTasks>
    let prompt: String
    let status: TaskRunsGetByTaskItemStatusEnum
    let children: String
    let environment: TaskRunsGetByTaskItemEnvironment?
}

struct TaskRunsGetRunDiffContextReturnTaskImagesItem: Decodable {
    let fileName: String?
    let storageId: ConvexId<ConvexTableStorage>
    let altText: String
}

struct TaskRunsGetRunDiffContextReturnTask: Decodable {
    let _id: ConvexId<ConvexTableTasks>
    @ConvexFloat var _creationTime: Double
    @OptionalConvexFloat var createdAt: Double?
    @OptionalConvexFloat var updatedAt: Double?
    let isArchived: Bool?
    let pinned: Bool?
    let isPreview: Bool?
    let isLocalWorkspace: Bool?
    let isCloudWorkspace: Bool?
    let linkedFromCloudTaskRunId: ConvexId<ConvexTableTaskRuns>?
    let description: String?
    let pullRequestTitle: String?
    let pullRequestDescription: String?
    let projectFullName: String?
    let baseBranch: String?
    let worktreePath: String?
    let generatedBranchName: String?
    @OptionalConvexFloat var lastActivityAt: Double?
    let environmentId: ConvexId<ConvexTableEnvironments>?
    let crownEvaluationStatus: TaskRunsGetRunDiffContextReturnTaskCrownEvaluationStatusEnum?
    let crownEvaluationError: String?
    let mergeStatus: TaskRunsGetRunDiffContextReturnTaskMergeStatusEnum?
    let images: [TaskRunsGetRunDiffContextReturnTaskImagesItem]?
    let screenshotStatus: TaskRunsGetRunDiffContextReturnTaskScreenshotStatusEnum?
    let screenshotRunId: ConvexId<ConvexTableTaskRuns>?
    let screenshotRequestId: String?
    @OptionalConvexFloat var screenshotRequestedAt: Double?
    @OptionalConvexFloat var screenshotCompletedAt: Double?
    let screenshotError: String?
    let screenshotStorageId: ConvexId<ConvexTableStorage>?
    let screenshotMimeType: String?
    let screenshotFileName: String?
    let screenshotCommitSha: String?
    let latestScreenshotSetId: ConvexId<ConvexTableTaskRunScreenshotSets>?
    let teamId: String
    let userId: String
    let text: String
    let isCompleted: Bool
}

struct TaskRunsGetRunDiffContextReturnTaskRunsItemEnvironmentError: Decodable {
    let devError: String?
    let maintenanceError: String?
}

struct TaskRunsGetRunDiffContextReturnTaskRunsItemPullRequestsItem: Decodable {
    @OptionalConvexFloat var number: Double?
    let url: String?
    let isDraft: Bool?
    let repoFullName: String
    let state: TaskRunsGetRunDiffContextReturnTaskRunsItemPullRequestsItemStateEnum
}

struct TaskRunsGetRunDiffContextReturnTaskRunsItemClaimsItemEvidence: Decodable {
    @OptionalConvexFloat var screenshotIndex: Double?
    let filePath: String?
    @OptionalConvexFloat var startLine: Double?
    @OptionalConvexFloat var endLine: Double?
    let type: String
}

struct TaskRunsGetRunDiffContextReturnTaskRunsItemClaimsItem: Decodable {
    let claim: String
    let evidence: TaskRunsGetRunDiffContextReturnTaskRunsItemClaimsItemEvidence
    @ConvexFloat var timestamp: Double
}

struct TaskRunsGetRunDiffContextReturnTaskRunsItemVscodePorts: Decodable {
    let `extension`: String?
    let proxy: String?
    let vnc: String?
    let vscode: String
    let worker: String
}

struct TaskRunsGetRunDiffContextReturnTaskRunsItemVscode: Decodable {
    let url: String?
    let containerName: String?
    let statusMessage: String?
    let ports: TaskRunsGetRunDiffContextReturnTaskRunsItemVscodePorts?
    let workspaceUrl: String?
    @OptionalConvexFloat var startedAt: Double?
    @OptionalConvexFloat var stoppedAt: Double?
    @OptionalConvexFloat var lastAccessedAt: Double?
    let keepAlive: Bool?
    @OptionalConvexFloat var scheduledStopAt: Double?
    let status: TaskRunsGetRunDiffContextReturnTaskRunsItemVscodeStatusEnum
    let provider: TaskRunsGetRunDiffContextReturnTaskRunsItemVscodeProviderEnum
}

struct TaskRunsGetRunDiffContextReturnTaskRunsItemNetworkingItem: Decodable {
    let status: TaskRunsGetRunDiffContextReturnTaskRunsItemNetworkingItemStatusEnum
    let url: String
    @ConvexFloat var port: Double
}

struct TaskRunsGetRunDiffContextReturnTaskRunsItemCustomPreviewsItem: Decodable {
    @ConvexFloat var createdAt: Double
    let url: String
}

struct TaskRunsGetRunDiffContextReturnTaskRunsItemEnvironment: Decodable {
    let name: String
    let selectedRepos: [String]?
    let _id: ConvexId<ConvexTableEnvironments>
}

struct TaskRunsGetRunDiffContextReturnTaskRunsItem: Decodable {
    let _id: ConvexId<ConvexTableTaskRuns>
    @ConvexFloat var _creationTime: Double
    let isArchived: Bool?
    let isLocalWorkspace: Bool?
    let isCloudWorkspace: Bool?
    let worktreePath: String?
    let environmentId: ConvexId<ConvexTableEnvironments>?
    let screenshotStorageId: ConvexId<ConvexTableStorage>?
    let screenshotMimeType: String?
    let screenshotFileName: String?
    let screenshotCommitSha: String?
    let latestScreenshotSetId: ConvexId<ConvexTableTaskRunScreenshotSets>?
    let parentRunId: ConvexId<ConvexTableTaskRuns>?
    let agentName: String?
    let summary: String?
    let isPreviewJob: Bool?
    let log: String?
    let newBranch: String?
    @OptionalConvexFloat var completedAt: Double?
    @OptionalConvexFloat var exitCode: Double?
    let environmentError: TaskRunsGetRunDiffContextReturnTaskRunsItemEnvironmentError?
    let errorMessage: String?
    let isCrowned: Bool?
    let crownReason: String?
    let pullRequestUrl: String?
    let pullRequestIsDraft: Bool?
    let pullRequestState: TaskRunsGetRunDiffContextReturnTaskRunsItemPullRequestStateEnum?
    @OptionalConvexFloat var pullRequestNumber: Double?
    let pullRequests: [TaskRunsGetRunDiffContextReturnTaskRunsItemPullRequestsItem]?
    @OptionalConvexFloat var diffsLastUpdated: Double?
    @OptionalConvexFloat var screenshotCapturedAt: Double?
    let claims: [TaskRunsGetRunDiffContextReturnTaskRunsItemClaimsItem]?
    @OptionalConvexFloat var claimsGeneratedAt: Double?
    let vscode: TaskRunsGetRunDiffContextReturnTaskRunsItemVscode?
    let networking: [TaskRunsGetRunDiffContextReturnTaskRunsItemNetworkingItem]?
    let customPreviews: [TaskRunsGetRunDiffContextReturnTaskRunsItemCustomPreviewsItem]?
    let teamId: String
    @ConvexFloat var createdAt: Double
    @ConvexFloat var updatedAt: Double
    let userId: String
    let taskId: ConvexId<ConvexTableTasks>
    let prompt: String
    let status: TaskRunsGetRunDiffContextReturnTaskRunsItemStatusEnum
    let children: String
    let environment: TaskRunsGetRunDiffContextReturnTaskRunsItemEnvironment?
}

struct TaskRunsGetRunDiffContextReturnBranchMetadataByRepoValueItem: Decodable {
    let _id: ConvexId<ConvexTableBranches>
    @ConvexFloat var _creationTime: Double
    @OptionalConvexFloat var lastActivityAt: Double?
    let repoId: ConvexId<ConvexTableRepos>?
    let lastCommitSha: String?
    let lastKnownBaseSha: String?
    let lastKnownMergeCommitSha: String?
    let teamId: String
    let name: String
    let userId: String
    let repo: String
}

struct TaskRunsGetRunDiffContextReturnScreenshotSets: Decodable {
    @ConvexFloat var length: Double
}

struct TaskRunsGetRunDiffContextReturn: Decodable {
    let task: TaskRunsGetRunDiffContextReturnTask?
    let taskRuns: [TaskRunsGetRunDiffContextReturnTaskRunsItem]
    let branchMetadataByRepo: [String: [TaskRunsGetRunDiffContextReturnBranchMetadataByRepoValueItem]]
    let screenshotSets: TaskRunsGetRunDiffContextReturnScreenshotSets
}

struct TaskRunsGetReturnEnvironmentError: Decodable {
    let devError: String?
    let maintenanceError: String?
}

struct TaskRunsGetReturnPullRequestsItem: Decodable {
    @OptionalConvexFloat var number: Double?
    let url: String?
    let isDraft: Bool?
    let repoFullName: String
    let state: TaskRunsGetReturnPullRequestsItemStateEnum
}

struct TaskRunsGetReturnClaimsItemEvidence: Decodable {
    @OptionalConvexFloat var screenshotIndex: Double?
    let filePath: String?
    @OptionalConvexFloat var startLine: Double?
    @OptionalConvexFloat var endLine: Double?
    let type: String
}

struct TaskRunsGetReturnClaimsItem: Decodable {
    let claim: String
    let evidence: TaskRunsGetReturnClaimsItemEvidence
    @ConvexFloat var timestamp: Double
}

struct TaskRunsGetReturnVscodePorts: Decodable {
    let `extension`: String?
    let proxy: String?
    let vnc: String?
    let vscode: String
    let worker: String
}

struct TaskRunsGetReturnVscode: Decodable {
    let url: String?
    let containerName: String?
    let statusMessage: String?
    let ports: TaskRunsGetReturnVscodePorts?
    let workspaceUrl: String?
    @OptionalConvexFloat var startedAt: Double?
    @OptionalConvexFloat var stoppedAt: Double?
    @OptionalConvexFloat var lastAccessedAt: Double?
    let keepAlive: Bool?
    @OptionalConvexFloat var scheduledStopAt: Double?
    let status: TaskRunsGetReturnVscodeStatusEnum
    let provider: TaskRunsGetReturnVscodeProviderEnum
}

struct TaskRunsGetReturnNetworkingItem: Decodable {
    let status: TaskRunsGetReturnNetworkingItemStatusEnum
    let url: String
    @ConvexFloat var port: Double
}

struct TaskRunsGetReturnCustomPreviewsItem: Decodable {
    @ConvexFloat var createdAt: Double
    let url: String
}

struct TaskRunsGetReturn: Decodable {
    let _id: ConvexId<ConvexTableTaskRuns>
    @ConvexFloat var _creationTime: Double
    let isArchived: Bool?
    let isLocalWorkspace: Bool?
    let isCloudWorkspace: Bool?
    let worktreePath: String?
    let environmentId: ConvexId<ConvexTableEnvironments>?
    let screenshotStorageId: ConvexId<ConvexTableStorage>?
    let screenshotMimeType: String?
    let screenshotFileName: String?
    let screenshotCommitSha: String?
    let latestScreenshotSetId: ConvexId<ConvexTableTaskRunScreenshotSets>?
    let parentRunId: ConvexId<ConvexTableTaskRuns>?
    let agentName: String?
    let summary: String?
    let isPreviewJob: Bool?
    let log: String?
    let newBranch: String?
    @OptionalConvexFloat var completedAt: Double?
    @OptionalConvexFloat var exitCode: Double?
    let environmentError: TaskRunsGetReturnEnvironmentError?
    let errorMessage: String?
    let isCrowned: Bool?
    let crownReason: String?
    let pullRequestUrl: String?
    let pullRequestIsDraft: Bool?
    let pullRequestState: TaskRunsGetReturnPullRequestStateEnum?
    @OptionalConvexFloat var pullRequestNumber: Double?
    let pullRequests: [TaskRunsGetReturnPullRequestsItem]?
    @OptionalConvexFloat var diffsLastUpdated: Double?
    @OptionalConvexFloat var screenshotCapturedAt: Double?
    let claims: [TaskRunsGetReturnClaimsItem]?
    @OptionalConvexFloat var claimsGeneratedAt: Double?
    let vscode: TaskRunsGetReturnVscode?
    let networking: [TaskRunsGetReturnNetworkingItem]?
    let customPreviews: [TaskRunsGetReturnCustomPreviewsItem]?
    let teamId: String
    @ConvexFloat var createdAt: Double
    @ConvexFloat var updatedAt: Double
    let userId: String
    let taskId: ConvexId<ConvexTableTasks>
    let prompt: String
    let status: TaskRunsGetReturnStatusEnum
}

struct TaskRunsSubscribeReturnEnvironmentError: Decodable {
    let devError: String?
    let maintenanceError: String?
}

struct TaskRunsSubscribeReturnPullRequestsItem: Decodable {
    @OptionalConvexFloat var number: Double?
    let url: String?
    let isDraft: Bool?
    let repoFullName: String
    let state: TaskRunsSubscribeReturnPullRequestsItemStateEnum
}

struct TaskRunsSubscribeReturnClaimsItemEvidence: Decodable {
    @OptionalConvexFloat var screenshotIndex: Double?
    let filePath: String?
    @OptionalConvexFloat var startLine: Double?
    @OptionalConvexFloat var endLine: Double?
    let type: String
}

struct TaskRunsSubscribeReturnClaimsItem: Decodable {
    let claim: String
    let evidence: TaskRunsSubscribeReturnClaimsItemEvidence
    @ConvexFloat var timestamp: Double
}

struct TaskRunsSubscribeReturnVscodePorts: Decodable {
    let `extension`: String?
    let proxy: String?
    let vnc: String?
    let vscode: String
    let worker: String
}

struct TaskRunsSubscribeReturnVscode: Decodable {
    let url: String?
    let containerName: String?
    let statusMessage: String?
    let ports: TaskRunsSubscribeReturnVscodePorts?
    let workspaceUrl: String?
    @OptionalConvexFloat var startedAt: Double?
    @OptionalConvexFloat var stoppedAt: Double?
    @OptionalConvexFloat var lastAccessedAt: Double?
    let keepAlive: Bool?
    @OptionalConvexFloat var scheduledStopAt: Double?
    let status: TaskRunsSubscribeReturnVscodeStatusEnum
    let provider: TaskRunsSubscribeReturnVscodeProviderEnum
}

struct TaskRunsSubscribeReturnNetworkingItem: Decodable {
    let status: TaskRunsSubscribeReturnNetworkingItemStatusEnum
    let url: String
    @ConvexFloat var port: Double
}

struct TaskRunsSubscribeReturnCustomPreviewsItem: Decodable {
    @ConvexFloat var createdAt: Double
    let url: String
}

struct TaskRunsSubscribeReturn: Decodable {
    let _id: ConvexId<ConvexTableTaskRuns>
    @ConvexFloat var _creationTime: Double
    let isArchived: Bool?
    let isLocalWorkspace: Bool?
    let isCloudWorkspace: Bool?
    let worktreePath: String?
    let environmentId: ConvexId<ConvexTableEnvironments>?
    let screenshotStorageId: ConvexId<ConvexTableStorage>?
    let screenshotMimeType: String?
    let screenshotFileName: String?
    let screenshotCommitSha: String?
    let latestScreenshotSetId: ConvexId<ConvexTableTaskRunScreenshotSets>?
    let parentRunId: ConvexId<ConvexTableTaskRuns>?
    let agentName: String?
    let summary: String?
    let isPreviewJob: Bool?
    let log: String?
    let newBranch: String?
    @OptionalConvexFloat var completedAt: Double?
    @OptionalConvexFloat var exitCode: Double?
    let environmentError: TaskRunsSubscribeReturnEnvironmentError?
    let errorMessage: String?
    let isCrowned: Bool?
    let crownReason: String?
    let pullRequestUrl: String?
    let pullRequestIsDraft: Bool?
    let pullRequestState: TaskRunsSubscribeReturnPullRequestStateEnum?
    @OptionalConvexFloat var pullRequestNumber: Double?
    let pullRequests: [TaskRunsSubscribeReturnPullRequestsItem]?
    @OptionalConvexFloat var diffsLastUpdated: Double?
    @OptionalConvexFloat var screenshotCapturedAt: Double?
    let claims: [TaskRunsSubscribeReturnClaimsItem]?
    @OptionalConvexFloat var claimsGeneratedAt: Double?
    let vscode: TaskRunsSubscribeReturnVscode?
    let networking: [TaskRunsSubscribeReturnNetworkingItem]?
    let customPreviews: [TaskRunsSubscribeReturnCustomPreviewsItem]?
    let teamId: String
    @ConvexFloat var createdAt: Double
    @ConvexFloat var updatedAt: Double
    let userId: String
    let taskId: ConvexId<ConvexTableTasks>
    let prompt: String
    let status: TaskRunsSubscribeReturnStatusEnum
}

struct TaskRunsUpdateBranchBatchArgsUpdatesItem: ConvexEncodable {
    let id: ConvexId<ConvexTableTaskRuns>
    let newBranch: String

    func convexEncode() throws -> String {
        var result: [String: ConvexEncodable?] = [:]
        result["id"] = id
        result["newBranch"] = newBranch
        return try result.convexEncode()
    }
}

struct TaskRunsGetJwtReturn: Decodable {
    let jwt: String
}

struct TaskRunsUpdateVSCodeInstanceArgsVscodePorts: ConvexEncodable {
    let `extension`: String?
    let proxy: String?
    let vnc: String?
    let vscode: String
    let worker: String

    func convexEncode() throws -> String {
        var result: [String: ConvexEncodable?] = [:]
        if let value = `extension` { result["extension"] = value }
        if let value = proxy { result["proxy"] = value }
        if let value = vnc { result["vnc"] = value }
        result["vscode"] = vscode
        result["worker"] = worker
        return try result.convexEncode()
    }
}

struct TaskRunsUpdateVSCodeInstanceArgsVscode: ConvexEncodable {
    let url: String?
    let containerName: String?
    let statusMessage: String?
    let ports: TaskRunsUpdateVSCodeInstanceArgsVscodePorts?
    let workspaceUrl: String?
    let startedAt: Double?
    let stoppedAt: Double?
    let status: TaskRunsUpdateVSCodeInstanceArgsVscodeStatusEnum
    let provider: TaskRunsUpdateVSCodeInstanceArgsVscodeProviderEnum

    func convexEncode() throws -> String {
        var result: [String: ConvexEncodable?] = [:]
        if let value = url { result["url"] = value }
        if let value = containerName { result["containerName"] = value }
        if let value = statusMessage { result["statusMessage"] = value }
        if let value = ports { result["ports"] = value }
        if let value = workspaceUrl { result["workspaceUrl"] = value }
        if let value = startedAt { result["startedAt"] = value }
        if let value = stoppedAt { result["stoppedAt"] = value }
        result["status"] = status
        result["provider"] = provider
        return try result.convexEncode()
    }
}

struct TaskRunsUpdateVSCodePortsArgsPorts: ConvexEncodable {
    let `extension`: String?
    let proxy: String?
    let vnc: String?
    let vscode: String
    let worker: String

    func convexEncode() throws -> String {
        var result: [String: ConvexEncodable?] = [:]
        if let value = `extension` { result["extension"] = value }
        if let value = proxy { result["proxy"] = value }
        if let value = vnc { result["vnc"] = value }
        result["vscode"] = vscode
        result["worker"] = worker
        return try result.convexEncode()
    }
}

struct TaskRunsGetByContainerNameReturnEnvironmentError: Decodable {
    let devError: String?
    let maintenanceError: String?
}

struct TaskRunsGetByContainerNameReturnPullRequestsItem: Decodable {
    @OptionalConvexFloat var number: Double?
    let url: String?
    let isDraft: Bool?
    let repoFullName: String
    let state: TaskRunsGetByContainerNameReturnPullRequestsItemStateEnum
}

struct TaskRunsGetByContainerNameReturnClaimsItemEvidence: Decodable {
    @OptionalConvexFloat var screenshotIndex: Double?
    let filePath: String?
    @OptionalConvexFloat var startLine: Double?
    @OptionalConvexFloat var endLine: Double?
    let type: String
}

struct TaskRunsGetByContainerNameReturnClaimsItem: Decodable {
    let claim: String
    let evidence: TaskRunsGetByContainerNameReturnClaimsItemEvidence
    @ConvexFloat var timestamp: Double
}

struct TaskRunsGetByContainerNameReturnVscodePorts: Decodable {
    let `extension`: String?
    let proxy: String?
    let vnc: String?
    let vscode: String
    let worker: String
}

struct TaskRunsGetByContainerNameReturnVscode: Decodable {
    let url: String?
    let containerName: String?
    let statusMessage: String?
    let ports: TaskRunsGetByContainerNameReturnVscodePorts?
    let workspaceUrl: String?
    @OptionalConvexFloat var startedAt: Double?
    @OptionalConvexFloat var stoppedAt: Double?
    @OptionalConvexFloat var lastAccessedAt: Double?
    let keepAlive: Bool?
    @OptionalConvexFloat var scheduledStopAt: Double?
    let status: TaskRunsGetByContainerNameReturnVscodeStatusEnum
    let provider: TaskRunsGetByContainerNameReturnVscodeProviderEnum
}

struct TaskRunsGetByContainerNameReturnNetworkingItem: Decodable {
    let status: TaskRunsGetByContainerNameReturnNetworkingItemStatusEnum
    let url: String
    @ConvexFloat var port: Double
}

struct TaskRunsGetByContainerNameReturnCustomPreviewsItem: Decodable {
    @ConvexFloat var createdAt: Double
    let url: String
}

struct TaskRunsGetByContainerNameReturn: Decodable {
    let _id: ConvexId<ConvexTableTaskRuns>
    @ConvexFloat var _creationTime: Double
    let isArchived: Bool?
    let isLocalWorkspace: Bool?
    let isCloudWorkspace: Bool?
    let worktreePath: String?
    let environmentId: ConvexId<ConvexTableEnvironments>?
    let screenshotStorageId: ConvexId<ConvexTableStorage>?
    let screenshotMimeType: String?
    let screenshotFileName: String?
    let screenshotCommitSha: String?
    let latestScreenshotSetId: ConvexId<ConvexTableTaskRunScreenshotSets>?
    let parentRunId: ConvexId<ConvexTableTaskRuns>?
    let agentName: String?
    let summary: String?
    let isPreviewJob: Bool?
    let log: String?
    let newBranch: String?
    @OptionalConvexFloat var completedAt: Double?
    @OptionalConvexFloat var exitCode: Double?
    let environmentError: TaskRunsGetByContainerNameReturnEnvironmentError?
    let errorMessage: String?
    let isCrowned: Bool?
    let crownReason: String?
    let pullRequestUrl: String?
    let pullRequestIsDraft: Bool?
    let pullRequestState: TaskRunsGetByContainerNameReturnPullRequestStateEnum?
    @OptionalConvexFloat var pullRequestNumber: Double?
    let pullRequests: [TaskRunsGetByContainerNameReturnPullRequestsItem]?
    @OptionalConvexFloat var diffsLastUpdated: Double?
    @OptionalConvexFloat var screenshotCapturedAt: Double?
    let claims: [TaskRunsGetByContainerNameReturnClaimsItem]?
    @OptionalConvexFloat var claimsGeneratedAt: Double?
    let vscode: TaskRunsGetByContainerNameReturnVscode?
    let networking: [TaskRunsGetByContainerNameReturnNetworkingItem]?
    let customPreviews: [TaskRunsGetByContainerNameReturnCustomPreviewsItem]?
    let teamId: String
    @ConvexFloat var createdAt: Double
    @ConvexFloat var updatedAt: Double
    let userId: String
    let taskId: ConvexId<ConvexTableTasks>
    let prompt: String
    let status: TaskRunsGetByContainerNameReturnStatusEnum
}

struct TaskRunsGetActiveVSCodeInstancesItemEnvironmentError: Decodable {
    let devError: String?
    let maintenanceError: String?
}

struct TaskRunsGetActiveVSCodeInstancesItemPullRequestsItem: Decodable {
    @OptionalConvexFloat var number: Double?
    let url: String?
    let isDraft: Bool?
    let repoFullName: String
    let state: TaskRunsGetActiveVSCodeInstancesItemPullRequestsItemStateEnum
}

struct TaskRunsGetActiveVSCodeInstancesItemClaimsItemEvidence: Decodable {
    @OptionalConvexFloat var screenshotIndex: Double?
    let filePath: String?
    @OptionalConvexFloat var startLine: Double?
    @OptionalConvexFloat var endLine: Double?
    let type: String
}

struct TaskRunsGetActiveVSCodeInstancesItemClaimsItem: Decodable {
    let claim: String
    let evidence: TaskRunsGetActiveVSCodeInstancesItemClaimsItemEvidence
    @ConvexFloat var timestamp: Double
}

struct TaskRunsGetActiveVSCodeInstancesItemVscodePorts: Decodable {
    let `extension`: String?
    let proxy: String?
    let vnc: String?
    let vscode: String
    let worker: String
}

struct TaskRunsGetActiveVSCodeInstancesItemVscode: Decodable {
    let url: String?
    let containerName: String?
    let statusMessage: String?
    let ports: TaskRunsGetActiveVSCodeInstancesItemVscodePorts?
    let workspaceUrl: String?
    @OptionalConvexFloat var startedAt: Double?
    @OptionalConvexFloat var stoppedAt: Double?
    @OptionalConvexFloat var lastAccessedAt: Double?
    let keepAlive: Bool?
    @OptionalConvexFloat var scheduledStopAt: Double?
    let status: TaskRunsGetActiveVSCodeInstancesItemVscodeStatusEnum
    let provider: TaskRunsGetActiveVSCodeInstancesItemVscodeProviderEnum
}

struct TaskRunsGetActiveVSCodeInstancesItemNetworkingItem: Decodable {
    let status: TaskRunsGetActiveVSCodeInstancesItemNetworkingItemStatusEnum
    let url: String
    @ConvexFloat var port: Double
}

struct TaskRunsGetActiveVSCodeInstancesItemCustomPreviewsItem: Decodable {
    @ConvexFloat var createdAt: Double
    let url: String
}

struct TaskRunsGetActiveVSCodeInstancesItem: Decodable {
    let _id: ConvexId<ConvexTableTaskRuns>
    @ConvexFloat var _creationTime: Double
    let isArchived: Bool?
    let isLocalWorkspace: Bool?
    let isCloudWorkspace: Bool?
    let worktreePath: String?
    let environmentId: ConvexId<ConvexTableEnvironments>?
    let screenshotStorageId: ConvexId<ConvexTableStorage>?
    let screenshotMimeType: String?
    let screenshotFileName: String?
    let screenshotCommitSha: String?
    let latestScreenshotSetId: ConvexId<ConvexTableTaskRunScreenshotSets>?
    let parentRunId: ConvexId<ConvexTableTaskRuns>?
    let agentName: String?
    let summary: String?
    let isPreviewJob: Bool?
    let log: String?
    let newBranch: String?
    @OptionalConvexFloat var completedAt: Double?
    @OptionalConvexFloat var exitCode: Double?
    let environmentError: TaskRunsGetActiveVSCodeInstancesItemEnvironmentError?
    let errorMessage: String?
    let isCrowned: Bool?
    let crownReason: String?
    let pullRequestUrl: String?
    let pullRequestIsDraft: Bool?
    let pullRequestState: TaskRunsGetActiveVSCodeInstancesItemPullRequestStateEnum?
    @OptionalConvexFloat var pullRequestNumber: Double?
    let pullRequests: [TaskRunsGetActiveVSCodeInstancesItemPullRequestsItem]?
    @OptionalConvexFloat var diffsLastUpdated: Double?
    @OptionalConvexFloat var screenshotCapturedAt: Double?
    let claims: [TaskRunsGetActiveVSCodeInstancesItemClaimsItem]?
    @OptionalConvexFloat var claimsGeneratedAt: Double?
    let vscode: TaskRunsGetActiveVSCodeInstancesItemVscode?
    let networking: [TaskRunsGetActiveVSCodeInstancesItemNetworkingItem]?
    let customPreviews: [TaskRunsGetActiveVSCodeInstancesItemCustomPreviewsItem]?
    let teamId: String
    @ConvexFloat var createdAt: Double
    @ConvexFloat var updatedAt: Double
    let userId: String
    let taskId: ConvexId<ConvexTableTasks>
    let prompt: String
    let status: TaskRunsGetActiveVSCodeInstancesItemStatusEnum
}

struct TaskRunsUpdatePullRequestUrlArgsPullRequestsItem: ConvexEncodable {
    let number: Double?
    let url: String?
    let isDraft: Bool?
    let repoFullName: String
    let state: TaskRunsUpdatePullRequestUrlArgsPullRequestsItemStateEnum

    func convexEncode() throws -> String {
        var result: [String: ConvexEncodable?] = [:]
        if let value = number { result["number"] = value }
        if let value = url { result["url"] = value }
        if let value = isDraft { result["isDraft"] = value }
        result["repoFullName"] = repoFullName
        result["state"] = state
        return try result.convexEncode()
    }
}

struct TaskRunsUpdatePullRequestStateArgsPullRequestsItem: ConvexEncodable {
    let number: Double?
    let url: String?
    let isDraft: Bool?
    let repoFullName: String
    let state: TaskRunsUpdatePullRequestStateArgsPullRequestsItemStateEnum

    func convexEncode() throws -> String {
        var result: [String: ConvexEncodable?] = [:]
        if let value = number { result["number"] = value }
        if let value = url { result["url"] = value }
        if let value = isDraft { result["isDraft"] = value }
        result["repoFullName"] = repoFullName
        result["state"] = state
        return try result.convexEncode()
    }
}

struct TaskRunsUpdateNetworkingArgsNetworkingItem: ConvexEncodable {
    let status: TaskRunsUpdateNetworkingArgsNetworkingItemStatusEnum
    let url: String
    let port: Double

    func convexEncode() throws -> String {
        var result: [String: ConvexEncodable?] = [:]
        result["status"] = status
        result["url"] = url
        result["port"] = port
        return try result.convexEncode()
    }
}

struct TaskRunsGetContainersToStopItemEnvironmentError: Decodable {
    let devError: String?
    let maintenanceError: String?
}

struct TaskRunsGetContainersToStopItemPullRequestsItem: Decodable {
    @OptionalConvexFloat var number: Double?
    let url: String?
    let isDraft: Bool?
    let repoFullName: String
    let state: TaskRunsGetContainersToStopItemPullRequestsItemStateEnum
}

struct TaskRunsGetContainersToStopItemClaimsItemEvidence: Decodable {
    @OptionalConvexFloat var screenshotIndex: Double?
    let filePath: String?
    @OptionalConvexFloat var startLine: Double?
    @OptionalConvexFloat var endLine: Double?
    let type: String
}

struct TaskRunsGetContainersToStopItemClaimsItem: Decodable {
    let claim: String
    let evidence: TaskRunsGetContainersToStopItemClaimsItemEvidence
    @ConvexFloat var timestamp: Double
}

struct TaskRunsGetContainersToStopItemVscodePorts: Decodable {
    let `extension`: String?
    let proxy: String?
    let vnc: String?
    let vscode: String
    let worker: String
}

struct TaskRunsGetContainersToStopItemVscode: Decodable {
    let url: String?
    let containerName: String?
    let statusMessage: String?
    let ports: TaskRunsGetContainersToStopItemVscodePorts?
    let workspaceUrl: String?
    @OptionalConvexFloat var startedAt: Double?
    @OptionalConvexFloat var stoppedAt: Double?
    @OptionalConvexFloat var lastAccessedAt: Double?
    let keepAlive: Bool?
    @OptionalConvexFloat var scheduledStopAt: Double?
    let status: TaskRunsGetContainersToStopItemVscodeStatusEnum
    let provider: TaskRunsGetContainersToStopItemVscodeProviderEnum
}

struct TaskRunsGetContainersToStopItemNetworkingItem: Decodable {
    let status: TaskRunsGetContainersToStopItemNetworkingItemStatusEnum
    let url: String
    @ConvexFloat var port: Double
}

struct TaskRunsGetContainersToStopItemCustomPreviewsItem: Decodable {
    @ConvexFloat var createdAt: Double
    let url: String
}

struct TaskRunsGetContainersToStopItem: Decodable {
    let _id: ConvexId<ConvexTableTaskRuns>
    @ConvexFloat var _creationTime: Double
    let isArchived: Bool?
    let isLocalWorkspace: Bool?
    let isCloudWorkspace: Bool?
    let worktreePath: String?
    let environmentId: ConvexId<ConvexTableEnvironments>?
    let screenshotStorageId: ConvexId<ConvexTableStorage>?
    let screenshotMimeType: String?
    let screenshotFileName: String?
    let screenshotCommitSha: String?
    let latestScreenshotSetId: ConvexId<ConvexTableTaskRunScreenshotSets>?
    let parentRunId: ConvexId<ConvexTableTaskRuns>?
    let agentName: String?
    let summary: String?
    let isPreviewJob: Bool?
    let log: String?
    let newBranch: String?
    @OptionalConvexFloat var completedAt: Double?
    @OptionalConvexFloat var exitCode: Double?
    let environmentError: TaskRunsGetContainersToStopItemEnvironmentError?
    let errorMessage: String?
    let isCrowned: Bool?
    let crownReason: String?
    let pullRequestUrl: String?
    let pullRequestIsDraft: Bool?
    let pullRequestState: TaskRunsGetContainersToStopItemPullRequestStateEnum?
    @OptionalConvexFloat var pullRequestNumber: Double?
    let pullRequests: [TaskRunsGetContainersToStopItemPullRequestsItem]?
    @OptionalConvexFloat var diffsLastUpdated: Double?
    @OptionalConvexFloat var screenshotCapturedAt: Double?
    let claims: [TaskRunsGetContainersToStopItemClaimsItem]?
    @OptionalConvexFloat var claimsGeneratedAt: Double?
    let vscode: TaskRunsGetContainersToStopItemVscode?
    let networking: [TaskRunsGetContainersToStopItemNetworkingItem]?
    let customPreviews: [TaskRunsGetContainersToStopItemCustomPreviewsItem]?
    let teamId: String
    @ConvexFloat var createdAt: Double
    @ConvexFloat var updatedAt: Double
    let userId: String
    let taskId: ConvexId<ConvexTableTasks>
    let prompt: String
    let status: TaskRunsGetContainersToStopItemStatusEnum
}

struct TaskRunsGetRunningContainersByCleanupPriorityReturnReviewContainersItemEnvironmentError: Decodable {
    let devError: String?
    let maintenanceError: String?
}

struct TaskRunsGetRunningContainersByCleanupPriorityReturnReviewContainersItemPullRequestsItem: Decodable {
    @OptionalConvexFloat var number: Double?
    let url: String?
    let isDraft: Bool?
    let repoFullName: String
    let state: TaskRunsGetRunningContainersByCleanupPriorityReturnReviewContainersItemPullRequestsItemStateEnum
}

struct TaskRunsGetRunningContainersByCleanupPriorityReturnReviewContainersItemClaimsItemEvidence: Decodable {
    @OptionalConvexFloat var screenshotIndex: Double?
    let filePath: String?
    @OptionalConvexFloat var startLine: Double?
    @OptionalConvexFloat var endLine: Double?
    let type: String
}

struct TaskRunsGetRunningContainersByCleanupPriorityReturnReviewContainersItemClaimsItem: Decodable {
    let claim: String
    let evidence: TaskRunsGetRunningContainersByCleanupPriorityReturnReviewContainersItemClaimsItemEvidence
    @ConvexFloat var timestamp: Double
}

struct TaskRunsGetRunningContainersByCleanupPriorityReturnReviewContainersItemVscodePorts: Decodable {
    let `extension`: String?
    let proxy: String?
    let vnc: String?
    let vscode: String
    let worker: String
}

struct TaskRunsGetRunningContainersByCleanupPriorityReturnReviewContainersItemVscode: Decodable {
    let url: String?
    let containerName: String?
    let statusMessage: String?
    let ports: TaskRunsGetRunningContainersByCleanupPriorityReturnReviewContainersItemVscodePorts?
    let workspaceUrl: String?
    @OptionalConvexFloat var startedAt: Double?
    @OptionalConvexFloat var stoppedAt: Double?
    @OptionalConvexFloat var lastAccessedAt: Double?
    let keepAlive: Bool?
    @OptionalConvexFloat var scheduledStopAt: Double?
    let status: TaskRunsGetRunningContainersByCleanupPriorityReturnReviewContainersItemVscodeStatusEnum
    let provider: TaskRunsGetRunningContainersByCleanupPriorityReturnReviewContainersItemVscodeProviderEnum
}

struct TaskRunsGetRunningContainersByCleanupPriorityReturnReviewContainersItemNetworkingItem: Decodable {
    let status: TaskRunsGetRunningContainersByCleanupPriorityReturnReviewContainersItemNetworkingItemStatusEnum
    let url: String
    @ConvexFloat var port: Double
}

struct TaskRunsGetRunningContainersByCleanupPriorityReturnReviewContainersItemCustomPreviewsItem: Decodable {
    @ConvexFloat var createdAt: Double
    let url: String
}

struct TaskRunsGetRunningContainersByCleanupPriorityReturnReviewContainersItem: Decodable {
    let _id: ConvexId<ConvexTableTaskRuns>
    @ConvexFloat var _creationTime: Double
    let isArchived: Bool?
    let isLocalWorkspace: Bool?
    let isCloudWorkspace: Bool?
    let worktreePath: String?
    let environmentId: ConvexId<ConvexTableEnvironments>?
    let screenshotStorageId: ConvexId<ConvexTableStorage>?
    let screenshotMimeType: String?
    let screenshotFileName: String?
    let screenshotCommitSha: String?
    let latestScreenshotSetId: ConvexId<ConvexTableTaskRunScreenshotSets>?
    let parentRunId: ConvexId<ConvexTableTaskRuns>?
    let agentName: String?
    let summary: String?
    let isPreviewJob: Bool?
    let log: String?
    let newBranch: String?
    @OptionalConvexFloat var completedAt: Double?
    @OptionalConvexFloat var exitCode: Double?
    let environmentError: TaskRunsGetRunningContainersByCleanupPriorityReturnReviewContainersItemEnvironmentError?
    let errorMessage: String?
    let isCrowned: Bool?
    let crownReason: String?
    let pullRequestUrl: String?
    let pullRequestIsDraft: Bool?
    let pullRequestState: TaskRunsGetRunningContainersByCleanupPriorityReturnReviewContainersItemPullRequestStateEnum?
    @OptionalConvexFloat var pullRequestNumber: Double?
    let pullRequests: [TaskRunsGetRunningContainersByCleanupPriorityReturnReviewContainersItemPullRequestsItem]?
    @OptionalConvexFloat var diffsLastUpdated: Double?
    @OptionalConvexFloat var screenshotCapturedAt: Double?
    let claims: [TaskRunsGetRunningContainersByCleanupPriorityReturnReviewContainersItemClaimsItem]?
    @OptionalConvexFloat var claimsGeneratedAt: Double?
    let vscode: TaskRunsGetRunningContainersByCleanupPriorityReturnReviewContainersItemVscode?
    let networking: [TaskRunsGetRunningContainersByCleanupPriorityReturnReviewContainersItemNetworkingItem]?
    let customPreviews: [TaskRunsGetRunningContainersByCleanupPriorityReturnReviewContainersItemCustomPreviewsItem]?
    let teamId: String
    @ConvexFloat var createdAt: Double
    @ConvexFloat var updatedAt: Double
    let userId: String
    let taskId: ConvexId<ConvexTableTasks>
    let prompt: String
    let status: TaskRunsGetRunningContainersByCleanupPriorityReturnReviewContainersItemStatusEnum
}

struct TaskRunsGetRunningContainersByCleanupPriorityReturnActiveContainersItemEnvironmentError: Decodable {
    let devError: String?
    let maintenanceError: String?
}

struct TaskRunsGetRunningContainersByCleanupPriorityReturnActiveContainersItemPullRequestsItem: Decodable {
    @OptionalConvexFloat var number: Double?
    let url: String?
    let isDraft: Bool?
    let repoFullName: String
    let state: TaskRunsGetRunningContainersByCleanupPriorityReturnActiveContainersItemPullRequestsItemStateEnum
}

struct TaskRunsGetRunningContainersByCleanupPriorityReturnActiveContainersItemClaimsItemEvidence: Decodable {
    @OptionalConvexFloat var screenshotIndex: Double?
    let filePath: String?
    @OptionalConvexFloat var startLine: Double?
    @OptionalConvexFloat var endLine: Double?
    let type: String
}

struct TaskRunsGetRunningContainersByCleanupPriorityReturnActiveContainersItemClaimsItem: Decodable {
    let claim: String
    let evidence: TaskRunsGetRunningContainersByCleanupPriorityReturnActiveContainersItemClaimsItemEvidence
    @ConvexFloat var timestamp: Double
}

struct TaskRunsGetRunningContainersByCleanupPriorityReturnActiveContainersItemVscodePorts: Decodable {
    let `extension`: String?
    let proxy: String?
    let vnc: String?
    let vscode: String
    let worker: String
}

struct TaskRunsGetRunningContainersByCleanupPriorityReturnActiveContainersItemVscode: Decodable {
    let url: String?
    let containerName: String?
    let statusMessage: String?
    let ports: TaskRunsGetRunningContainersByCleanupPriorityReturnActiveContainersItemVscodePorts?
    let workspaceUrl: String?
    @OptionalConvexFloat var startedAt: Double?
    @OptionalConvexFloat var stoppedAt: Double?
    @OptionalConvexFloat var lastAccessedAt: Double?
    let keepAlive: Bool?
    @OptionalConvexFloat var scheduledStopAt: Double?
    let status: TaskRunsGetRunningContainersByCleanupPriorityReturnActiveContainersItemVscodeStatusEnum
    let provider: TaskRunsGetRunningContainersByCleanupPriorityReturnActiveContainersItemVscodeProviderEnum
}

struct TaskRunsGetRunningContainersByCleanupPriorityReturnActiveContainersItemNetworkingItem: Decodable {
    let status: TaskRunsGetRunningContainersByCleanupPriorityReturnActiveContainersItemNetworkingItemStatusEnum
    let url: String
    @ConvexFloat var port: Double
}

struct TaskRunsGetRunningContainersByCleanupPriorityReturnActiveContainersItemCustomPreviewsItem: Decodable {
    @ConvexFloat var createdAt: Double
    let url: String
}

struct TaskRunsGetRunningContainersByCleanupPriorityReturnActiveContainersItem: Decodable {
    let _id: ConvexId<ConvexTableTaskRuns>
    @ConvexFloat var _creationTime: Double
    let isArchived: Bool?
    let isLocalWorkspace: Bool?
    let isCloudWorkspace: Bool?
    let worktreePath: String?
    let environmentId: ConvexId<ConvexTableEnvironments>?
    let screenshotStorageId: ConvexId<ConvexTableStorage>?
    let screenshotMimeType: String?
    let screenshotFileName: String?
    let screenshotCommitSha: String?
    let latestScreenshotSetId: ConvexId<ConvexTableTaskRunScreenshotSets>?
    let parentRunId: ConvexId<ConvexTableTaskRuns>?
    let agentName: String?
    let summary: String?
    let isPreviewJob: Bool?
    let log: String?
    let newBranch: String?
    @OptionalConvexFloat var completedAt: Double?
    @OptionalConvexFloat var exitCode: Double?
    let environmentError: TaskRunsGetRunningContainersByCleanupPriorityReturnActiveContainersItemEnvironmentError?
    let errorMessage: String?
    let isCrowned: Bool?
    let crownReason: String?
    let pullRequestUrl: String?
    let pullRequestIsDraft: Bool?
    let pullRequestState: TaskRunsGetRunningContainersByCleanupPriorityReturnActiveContainersItemPullRequestStateEnum?
    @OptionalConvexFloat var pullRequestNumber: Double?
    let pullRequests: [TaskRunsGetRunningContainersByCleanupPriorityReturnActiveContainersItemPullRequestsItem]?
    @OptionalConvexFloat var diffsLastUpdated: Double?
    @OptionalConvexFloat var screenshotCapturedAt: Double?
    let claims: [TaskRunsGetRunningContainersByCleanupPriorityReturnActiveContainersItemClaimsItem]?
    @OptionalConvexFloat var claimsGeneratedAt: Double?
    let vscode: TaskRunsGetRunningContainersByCleanupPriorityReturnActiveContainersItemVscode?
    let networking: [TaskRunsGetRunningContainersByCleanupPriorityReturnActiveContainersItemNetworkingItem]?
    let customPreviews: [TaskRunsGetRunningContainersByCleanupPriorityReturnActiveContainersItemCustomPreviewsItem]?
    let teamId: String
    @ConvexFloat var createdAt: Double
    @ConvexFloat var updatedAt: Double
    let userId: String
    let taskId: ConvexId<ConvexTableTasks>
    let prompt: String
    let status: TaskRunsGetRunningContainersByCleanupPriorityReturnActiveContainersItemStatusEnum
}

struct TaskRunsGetRunningContainersByCleanupPriorityReturnPrioritizedForCleanupItemEnvironmentError: Decodable {
    let devError: String?
    let maintenanceError: String?
}

struct TaskRunsGetRunningContainersByCleanupPriorityReturnPrioritizedForCleanupItemPullRequestsItem: Decodable {
    @OptionalConvexFloat var number: Double?
    let url: String?
    let isDraft: Bool?
    let repoFullName: String
    let state: TaskRunsGetRunningContainersByCleanupPriorityReturnPrioritizedForCleanupItemPullRequestsItemStateEnum
}

struct TaskRunsGetRunningContainersByCleanupPriorityReturnPrioritizedForCleanupItemClaimsItemEvidence: Decodable {
    @OptionalConvexFloat var screenshotIndex: Double?
    let filePath: String?
    @OptionalConvexFloat var startLine: Double?
    @OptionalConvexFloat var endLine: Double?
    let type: String
}

struct TaskRunsGetRunningContainersByCleanupPriorityReturnPrioritizedForCleanupItemClaimsItem: Decodable {
    let claim: String
    let evidence: TaskRunsGetRunningContainersByCleanupPriorityReturnPrioritizedForCleanupItemClaimsItemEvidence
    @ConvexFloat var timestamp: Double
}

struct TaskRunsGetRunningContainersByCleanupPriorityReturnPrioritizedForCleanupItemVscodePorts: Decodable {
    let `extension`: String?
    let proxy: String?
    let vnc: String?
    let vscode: String
    let worker: String
}

struct TaskRunsGetRunningContainersByCleanupPriorityReturnPrioritizedForCleanupItemVscode: Decodable {
    let url: String?
    let containerName: String?
    let statusMessage: String?
    let ports: TaskRunsGetRunningContainersByCleanupPriorityReturnPrioritizedForCleanupItemVscodePorts?
    let workspaceUrl: String?
    @OptionalConvexFloat var startedAt: Double?
    @OptionalConvexFloat var stoppedAt: Double?
    @OptionalConvexFloat var lastAccessedAt: Double?
    let keepAlive: Bool?
    @OptionalConvexFloat var scheduledStopAt: Double?
    let status: TaskRunsGetRunningContainersByCleanupPriorityReturnPrioritizedForCleanupItemVscodeStatusEnum
    let provider: TaskRunsGetRunningContainersByCleanupPriorityReturnPrioritizedForCleanupItemVscodeProviderEnum
}

struct TaskRunsGetRunningContainersByCleanupPriorityReturnPrioritizedForCleanupItemNetworkingItem: Decodable {
    let status: TaskRunsGetRunningContainersByCleanupPriorityReturnPrioritizedForCleanupItemNetworkingItemStatusEnum
    let url: String
    @ConvexFloat var port: Double
}

struct TaskRunsGetRunningContainersByCleanupPriorityReturnPrioritizedForCleanupItemCustomPreviewsItem: Decodable {
    @ConvexFloat var createdAt: Double
    let url: String
}

struct TaskRunsGetRunningContainersByCleanupPriorityReturnPrioritizedForCleanupItem: Decodable {
    let _id: ConvexId<ConvexTableTaskRuns>
    @ConvexFloat var _creationTime: Double
    let isArchived: Bool?
    let isLocalWorkspace: Bool?
    let isCloudWorkspace: Bool?
    let worktreePath: String?
    let environmentId: ConvexId<ConvexTableEnvironments>?
    let screenshotStorageId: ConvexId<ConvexTableStorage>?
    let screenshotMimeType: String?
    let screenshotFileName: String?
    let screenshotCommitSha: String?
    let latestScreenshotSetId: ConvexId<ConvexTableTaskRunScreenshotSets>?
    let parentRunId: ConvexId<ConvexTableTaskRuns>?
    let agentName: String?
    let summary: String?
    let isPreviewJob: Bool?
    let log: String?
    let newBranch: String?
    @OptionalConvexFloat var completedAt: Double?
    @OptionalConvexFloat var exitCode: Double?
    let environmentError: TaskRunsGetRunningContainersByCleanupPriorityReturnPrioritizedForCleanupItemEnvironmentError?
    let errorMessage: String?
    let isCrowned: Bool?
    let crownReason: String?
    let pullRequestUrl: String?
    let pullRequestIsDraft: Bool?
    let pullRequestState: TaskRunsGetRunningContainersByCleanupPriorityReturnPrioritizedForCleanupItemPullRequestStateEnum?
    @OptionalConvexFloat var pullRequestNumber: Double?
    let pullRequests: [TaskRunsGetRunningContainersByCleanupPriorityReturnPrioritizedForCleanupItemPullRequestsItem]?
    @OptionalConvexFloat var diffsLastUpdated: Double?
    @OptionalConvexFloat var screenshotCapturedAt: Double?
    let claims: [TaskRunsGetRunningContainersByCleanupPriorityReturnPrioritizedForCleanupItemClaimsItem]?
    @OptionalConvexFloat var claimsGeneratedAt: Double?
    let vscode: TaskRunsGetRunningContainersByCleanupPriorityReturnPrioritizedForCleanupItemVscode?
    let networking: [TaskRunsGetRunningContainersByCleanupPriorityReturnPrioritizedForCleanupItemNetworkingItem]?
    let customPreviews: [TaskRunsGetRunningContainersByCleanupPriorityReturnPrioritizedForCleanupItemCustomPreviewsItem]?
    let teamId: String
    @ConvexFloat var createdAt: Double
    @ConvexFloat var updatedAt: Double
    let userId: String
    let taskId: ConvexId<ConvexTableTasks>
    let prompt: String
    let status: TaskRunsGetRunningContainersByCleanupPriorityReturnPrioritizedForCleanupItemStatusEnum
}

struct TaskRunsGetRunningContainersByCleanupPriorityReturn: Decodable {
    @ConvexFloat var total: Double
    let reviewContainers: [TaskRunsGetRunningContainersByCleanupPriorityReturnReviewContainersItem]
    let activeContainers: [TaskRunsGetRunningContainersByCleanupPriorityReturnActiveContainersItem]
    let prioritizedForCleanup: [TaskRunsGetRunningContainersByCleanupPriorityReturnPrioritizedForCleanupItem]
    @ConvexFloat var protectedCount: Double
}

struct TasksGetItemImagesItem: Decodable {
    let fileName: String?
    let storageId: ConvexId<ConvexTableStorage>
    let altText: String
}

struct TasksGetItem: Decodable {
    let hasUnread: Bool
    let _id: ConvexId<ConvexTableTasks>
    @ConvexFloat var _creationTime: Double
    @OptionalConvexFloat var createdAt: Double?
    @OptionalConvexFloat var updatedAt: Double?
    let isArchived: Bool?
    let pinned: Bool?
    let isPreview: Bool?
    let isLocalWorkspace: Bool?
    let isCloudWorkspace: Bool?
    let linkedFromCloudTaskRunId: ConvexId<ConvexTableTaskRuns>?
    let description: String?
    let pullRequestTitle: String?
    let pullRequestDescription: String?
    let projectFullName: String?
    let baseBranch: String?
    let worktreePath: String?
    let generatedBranchName: String?
    @OptionalConvexFloat var lastActivityAt: Double?
    let environmentId: ConvexId<ConvexTableEnvironments>?
    let crownEvaluationStatus: TasksGetItemCrownEvaluationStatusEnum?
    let crownEvaluationError: String?
    let mergeStatus: TasksGetItemMergeStatusEnum?
    let images: [TasksGetItemImagesItem]?
    let screenshotStatus: TasksGetItemScreenshotStatusEnum?
    let screenshotRunId: ConvexId<ConvexTableTaskRuns>?
    let screenshotRequestId: String?
    @OptionalConvexFloat var screenshotRequestedAt: Double?
    @OptionalConvexFloat var screenshotCompletedAt: Double?
    let screenshotError: String?
    let screenshotStorageId: ConvexId<ConvexTableStorage>?
    let screenshotMimeType: String?
    let screenshotFileName: String?
    let screenshotCommitSha: String?
    let latestScreenshotSetId: ConvexId<ConvexTableTaskRunScreenshotSets>?
    let teamId: String
    let userId: String
    let text: String
    let isCompleted: Bool
}

struct TasksGetArchivedPaginatedArgsPaginationOpts: ConvexEncodable {
    let id: Double?
    let endCursor: String?
    let maximumRowsRead: Double?
    let maximumBytesRead: Double?
    let numItems: Double
    let cursor: String?

    func convexEncode() throws -> String {
        var result: [String: ConvexEncodable?] = [:]
        if let value = id { result["id"] = value }
        if let value = endCursor { result["endCursor"] = value }
        if let value = maximumRowsRead { result["maximumRowsRead"] = value }
        if let value = maximumBytesRead { result["maximumBytesRead"] = value }
        result["numItems"] = numItems
        if let value = cursor { result["cursor"] = value } else { result["cursor"] = ConvexNull() }
        return try result.convexEncode()
    }
}

struct TasksGetArchivedPaginatedReturnPageItemImagesItem: Decodable {
    let fileName: String?
    let storageId: ConvexId<ConvexTableStorage>
    let altText: String
}

struct TasksGetArchivedPaginatedReturnPageItem: Decodable {
    let hasUnread: Bool
    let _id: ConvexId<ConvexTableTasks>
    @ConvexFloat var _creationTime: Double
    @OptionalConvexFloat var createdAt: Double?
    @OptionalConvexFloat var updatedAt: Double?
    let isArchived: Bool?
    let pinned: Bool?
    let isPreview: Bool?
    let isLocalWorkspace: Bool?
    let isCloudWorkspace: Bool?
    let linkedFromCloudTaskRunId: ConvexId<ConvexTableTaskRuns>?
    let description: String?
    let pullRequestTitle: String?
    let pullRequestDescription: String?
    let projectFullName: String?
    let baseBranch: String?
    let worktreePath: String?
    let generatedBranchName: String?
    @OptionalConvexFloat var lastActivityAt: Double?
    let environmentId: ConvexId<ConvexTableEnvironments>?
    let crownEvaluationStatus: TasksGetArchivedPaginatedReturnPageItemCrownEvaluationStatusEnum?
    let crownEvaluationError: String?
    let mergeStatus: TasksGetArchivedPaginatedReturnPageItemMergeStatusEnum?
    let images: [TasksGetArchivedPaginatedReturnPageItemImagesItem]?
    let screenshotStatus: TasksGetArchivedPaginatedReturnPageItemScreenshotStatusEnum?
    let screenshotRunId: ConvexId<ConvexTableTaskRuns>?
    let screenshotRequestId: String?
    @OptionalConvexFloat var screenshotRequestedAt: Double?
    @OptionalConvexFloat var screenshotCompletedAt: Double?
    let screenshotError: String?
    let screenshotStorageId: ConvexId<ConvexTableStorage>?
    let screenshotMimeType: String?
    let screenshotFileName: String?
    let screenshotCommitSha: String?
    let latestScreenshotSetId: ConvexId<ConvexTableTaskRunScreenshotSets>?
    let teamId: String
    let userId: String
    let text: String
    let isCompleted: Bool
}

struct TasksGetArchivedPaginatedReturn: Decodable {
    let page: [TasksGetArchivedPaginatedReturnPageItem]
    let isDone: Bool
    let continueCursor: String
    let splitCursor: String?
    let pageStatus: TasksGetArchivedPaginatedReturnPageStatusEnum?
}

struct TasksGetWithNotificationOrderItemImagesItem: Decodable {
    let fileName: String?
    let storageId: ConvexId<ConvexTableStorage>
    let altText: String
}

struct TasksGetWithNotificationOrderItem: Decodable {
    let hasUnread: Bool
    let _id: ConvexId<ConvexTableTasks>
    @ConvexFloat var _creationTime: Double
    @OptionalConvexFloat var createdAt: Double?
    @OptionalConvexFloat var updatedAt: Double?
    let isArchived: Bool?
    let pinned: Bool?
    let isPreview: Bool?
    let isLocalWorkspace: Bool?
    let isCloudWorkspace: Bool?
    let linkedFromCloudTaskRunId: ConvexId<ConvexTableTaskRuns>?
    let description: String?
    let pullRequestTitle: String?
    let pullRequestDescription: String?
    let projectFullName: String?
    let baseBranch: String?
    let worktreePath: String?
    let generatedBranchName: String?
    @OptionalConvexFloat var lastActivityAt: Double?
    let environmentId: ConvexId<ConvexTableEnvironments>?
    let crownEvaluationStatus: TasksGetWithNotificationOrderItemCrownEvaluationStatusEnum?
    let crownEvaluationError: String?
    let mergeStatus: TasksGetWithNotificationOrderItemMergeStatusEnum?
    let images: [TasksGetWithNotificationOrderItemImagesItem]?
    let screenshotStatus: TasksGetWithNotificationOrderItemScreenshotStatusEnum?
    let screenshotRunId: ConvexId<ConvexTableTaskRuns>?
    let screenshotRequestId: String?
    @OptionalConvexFloat var screenshotRequestedAt: Double?
    @OptionalConvexFloat var screenshotCompletedAt: Double?
    let screenshotError: String?
    let screenshotStorageId: ConvexId<ConvexTableStorage>?
    let screenshotMimeType: String?
    let screenshotFileName: String?
    let screenshotCommitSha: String?
    let latestScreenshotSetId: ConvexId<ConvexTableTaskRunScreenshotSets>?
    let teamId: String
    let userId: String
    let text: String
    let isCompleted: Bool
}

struct TasksGetPreviewTasksItemImagesItem: Decodable {
    let fileName: String?
    let storageId: ConvexId<ConvexTableStorage>
    let altText: String
}

struct TasksGetPreviewTasksItem: Decodable {
    let _id: ConvexId<ConvexTableTasks>
    @ConvexFloat var _creationTime: Double
    @OptionalConvexFloat var createdAt: Double?
    @OptionalConvexFloat var updatedAt: Double?
    let isArchived: Bool?
    let pinned: Bool?
    let isPreview: Bool?
    let isLocalWorkspace: Bool?
    let isCloudWorkspace: Bool?
    let linkedFromCloudTaskRunId: ConvexId<ConvexTableTaskRuns>?
    let description: String?
    let pullRequestTitle: String?
    let pullRequestDescription: String?
    let projectFullName: String?
    let baseBranch: String?
    let worktreePath: String?
    let generatedBranchName: String?
    @OptionalConvexFloat var lastActivityAt: Double?
    let environmentId: ConvexId<ConvexTableEnvironments>?
    let crownEvaluationStatus: TasksGetPreviewTasksItemCrownEvaluationStatusEnum?
    let crownEvaluationError: String?
    let mergeStatus: TasksGetPreviewTasksItemMergeStatusEnum?
    let images: [TasksGetPreviewTasksItemImagesItem]?
    let screenshotStatus: TasksGetPreviewTasksItemScreenshotStatusEnum?
    let screenshotRunId: ConvexId<ConvexTableTaskRuns>?
    let screenshotRequestId: String?
    @OptionalConvexFloat var screenshotRequestedAt: Double?
    @OptionalConvexFloat var screenshotCompletedAt: Double?
    let screenshotError: String?
    let screenshotStorageId: ConvexId<ConvexTableStorage>?
    let screenshotMimeType: String?
    let screenshotFileName: String?
    let screenshotCommitSha: String?
    let latestScreenshotSetId: ConvexId<ConvexTableTaskRunScreenshotSets>?
    let teamId: String
    let userId: String
    let text: String
    let isCompleted: Bool
}

struct TasksGetPinnedItemImagesItem: Decodable {
    let fileName: String?
    let storageId: ConvexId<ConvexTableStorage>
    let altText: String
}

struct TasksGetPinnedItem: Decodable {
    let hasUnread: Bool
    let _id: ConvexId<ConvexTableTasks>
    @ConvexFloat var _creationTime: Double
    @OptionalConvexFloat var createdAt: Double?
    @OptionalConvexFloat var updatedAt: Double?
    let isArchived: Bool?
    let pinned: Bool?
    let isPreview: Bool?
    let isLocalWorkspace: Bool?
    let isCloudWorkspace: Bool?
    let linkedFromCloudTaskRunId: ConvexId<ConvexTableTaskRuns>?
    let description: String?
    let pullRequestTitle: String?
    let pullRequestDescription: String?
    let projectFullName: String?
    let baseBranch: String?
    let worktreePath: String?
    let generatedBranchName: String?
    @OptionalConvexFloat var lastActivityAt: Double?
    let environmentId: ConvexId<ConvexTableEnvironments>?
    let crownEvaluationStatus: TasksGetPinnedItemCrownEvaluationStatusEnum?
    let crownEvaluationError: String?
    let mergeStatus: TasksGetPinnedItemMergeStatusEnum?
    let images: [TasksGetPinnedItemImagesItem]?
    let screenshotStatus: TasksGetPinnedItemScreenshotStatusEnum?
    let screenshotRunId: ConvexId<ConvexTableTaskRuns>?
    let screenshotRequestId: String?
    @OptionalConvexFloat var screenshotRequestedAt: Double?
    @OptionalConvexFloat var screenshotCompletedAt: Double?
    let screenshotError: String?
    let screenshotStorageId: ConvexId<ConvexTableStorage>?
    let screenshotMimeType: String?
    let screenshotFileName: String?
    let screenshotCommitSha: String?
    let latestScreenshotSetId: ConvexId<ConvexTableTaskRunScreenshotSets>?
    let teamId: String
    let userId: String
    let text: String
    let isCompleted: Bool
}

struct TasksGetTasksWithTaskRunsItemSelectedTaskRunEnvironmentError: Decodable {
    let devError: String?
    let maintenanceError: String?
}

struct TasksGetTasksWithTaskRunsItemSelectedTaskRunPullRequestsItem: Decodable {
    @OptionalConvexFloat var number: Double?
    let url: String?
    let isDraft: Bool?
    let repoFullName: String
    let state: TasksGetTasksWithTaskRunsItemSelectedTaskRunPullRequestsItemStateEnum
}

struct TasksGetTasksWithTaskRunsItemSelectedTaskRunClaimsItemEvidence: Decodable {
    @OptionalConvexFloat var screenshotIndex: Double?
    let filePath: String?
    @OptionalConvexFloat var startLine: Double?
    @OptionalConvexFloat var endLine: Double?
    let type: String
}

struct TasksGetTasksWithTaskRunsItemSelectedTaskRunClaimsItem: Decodable {
    let claim: String
    let evidence: TasksGetTasksWithTaskRunsItemSelectedTaskRunClaimsItemEvidence
    @ConvexFloat var timestamp: Double
}

struct TasksGetTasksWithTaskRunsItemSelectedTaskRunVscodePorts: Decodable {
    let `extension`: String?
    let proxy: String?
    let vnc: String?
    let vscode: String
    let worker: String
}

struct TasksGetTasksWithTaskRunsItemSelectedTaskRunVscode: Decodable {
    let url: String?
    let containerName: String?
    let statusMessage: String?
    let ports: TasksGetTasksWithTaskRunsItemSelectedTaskRunVscodePorts?
    let workspaceUrl: String?
    @OptionalConvexFloat var startedAt: Double?
    @OptionalConvexFloat var stoppedAt: Double?
    @OptionalConvexFloat var lastAccessedAt: Double?
    let keepAlive: Bool?
    @OptionalConvexFloat var scheduledStopAt: Double?
    let status: TasksGetTasksWithTaskRunsItemSelectedTaskRunVscodeStatusEnum
    let provider: TasksGetTasksWithTaskRunsItemSelectedTaskRunVscodeProviderEnum
}

struct TasksGetTasksWithTaskRunsItemSelectedTaskRunNetworkingItem: Decodable {
    let status: TasksGetTasksWithTaskRunsItemSelectedTaskRunNetworkingItemStatusEnum
    let url: String
    @ConvexFloat var port: Double
}

struct TasksGetTasksWithTaskRunsItemSelectedTaskRunCustomPreviewsItem: Decodable {
    @ConvexFloat var createdAt: Double
    let url: String
}

struct TasksGetTasksWithTaskRunsItemSelectedTaskRun: Decodable {
    let _id: ConvexId<ConvexTableTaskRuns>
    @ConvexFloat var _creationTime: Double
    let isArchived: Bool?
    let isLocalWorkspace: Bool?
    let isCloudWorkspace: Bool?
    let worktreePath: String?
    let environmentId: ConvexId<ConvexTableEnvironments>?
    let screenshotStorageId: ConvexId<ConvexTableStorage>?
    let screenshotMimeType: String?
    let screenshotFileName: String?
    let screenshotCommitSha: String?
    let latestScreenshotSetId: ConvexId<ConvexTableTaskRunScreenshotSets>?
    let parentRunId: ConvexId<ConvexTableTaskRuns>?
    let agentName: String?
    let summary: String?
    let isPreviewJob: Bool?
    let log: String?
    let newBranch: String?
    @OptionalConvexFloat var completedAt: Double?
    @OptionalConvexFloat var exitCode: Double?
    let environmentError: TasksGetTasksWithTaskRunsItemSelectedTaskRunEnvironmentError?
    let errorMessage: String?
    let isCrowned: Bool?
    let crownReason: String?
    let pullRequestUrl: String?
    let pullRequestIsDraft: Bool?
    let pullRequestState: TasksGetTasksWithTaskRunsItemSelectedTaskRunPullRequestStateEnum?
    @OptionalConvexFloat var pullRequestNumber: Double?
    let pullRequests: [TasksGetTasksWithTaskRunsItemSelectedTaskRunPullRequestsItem]?
    @OptionalConvexFloat var diffsLastUpdated: Double?
    @OptionalConvexFloat var screenshotCapturedAt: Double?
    let claims: [TasksGetTasksWithTaskRunsItemSelectedTaskRunClaimsItem]?
    @OptionalConvexFloat var claimsGeneratedAt: Double?
    let vscode: TasksGetTasksWithTaskRunsItemSelectedTaskRunVscode?
    let networking: [TasksGetTasksWithTaskRunsItemSelectedTaskRunNetworkingItem]?
    let customPreviews: [TasksGetTasksWithTaskRunsItemSelectedTaskRunCustomPreviewsItem]?
    let teamId: String
    @ConvexFloat var createdAt: Double
    @ConvexFloat var updatedAt: Double
    let userId: String
    let taskId: ConvexId<ConvexTableTasks>
    let prompt: String
    let status: TasksGetTasksWithTaskRunsItemSelectedTaskRunStatusEnum
}

struct TasksGetTasksWithTaskRunsItemImagesItem: Decodable {
    let fileName: String?
    let storageId: ConvexId<ConvexTableStorage>
    let altText: String
}

struct TasksGetTasksWithTaskRunsItem: Decodable {
    let selectedTaskRun: TasksGetTasksWithTaskRunsItemSelectedTaskRun
    let _id: ConvexId<ConvexTableTasks>
    @ConvexFloat var _creationTime: Double
    @OptionalConvexFloat var createdAt: Double?
    @OptionalConvexFloat var updatedAt: Double?
    let isArchived: Bool?
    let pinned: Bool?
    let isPreview: Bool?
    let isLocalWorkspace: Bool?
    let isCloudWorkspace: Bool?
    let linkedFromCloudTaskRunId: ConvexId<ConvexTableTaskRuns>?
    let description: String?
    let pullRequestTitle: String?
    let pullRequestDescription: String?
    let projectFullName: String?
    let baseBranch: String?
    let worktreePath: String?
    let generatedBranchName: String?
    @OptionalConvexFloat var lastActivityAt: Double?
    let environmentId: ConvexId<ConvexTableEnvironments>?
    let crownEvaluationStatus: TasksGetTasksWithTaskRunsItemCrownEvaluationStatusEnum?
    let crownEvaluationError: String?
    let mergeStatus: TasksGetTasksWithTaskRunsItemMergeStatusEnum?
    let images: [TasksGetTasksWithTaskRunsItemImagesItem]?
    let screenshotStatus: TasksGetTasksWithTaskRunsItemScreenshotStatusEnum?
    let screenshotRunId: ConvexId<ConvexTableTaskRuns>?
    let screenshotRequestId: String?
    @OptionalConvexFloat var screenshotRequestedAt: Double?
    @OptionalConvexFloat var screenshotCompletedAt: Double?
    let screenshotError: String?
    let screenshotStorageId: ConvexId<ConvexTableStorage>?
    let screenshotMimeType: String?
    let screenshotFileName: String?
    let screenshotCommitSha: String?
    let latestScreenshotSetId: ConvexId<ConvexTableTaskRunScreenshotSets>?
    let teamId: String
    let userId: String
    let text: String
    let isCompleted: Bool
}

struct TasksCreateArgsImagesItem: ConvexEncodable {
    let fileName: String?
    let storageId: ConvexId<ConvexTableStorage>
    let altText: String

    func convexEncode() throws -> String {
        var result: [String: ConvexEncodable?] = [:]
        if let value = fileName { result["fileName"] = value }
        result["storageId"] = storageId
        result["altText"] = altText
        return try result.convexEncode()
    }
}

struct TasksCreateReturn: Decodable {
    let taskId: ConvexId<ConvexTableTasks>
    let taskRunIds: [ConvexId<ConvexTableTaskRuns>]?
}

struct TasksGetByIdArgsId: ConvexEncodable {
    let length: Double

    func convexEncode() throws -> String {
        var result: [String: ConvexEncodable?] = [:]
        result["length"] = length
        return try result.convexEncode()
    }
}

struct TasksGetByIdReturnImagesItem: Decodable {
    let fileName: String?
    let storageId: ConvexId<ConvexTableStorage>
    let altText: String
}

struct TasksGetByIdReturn: Decodable {
    let _id: ConvexId<ConvexTableTasks>
    @ConvexFloat var _creationTime: Double
    @OptionalConvexFloat var createdAt: Double?
    @OptionalConvexFloat var updatedAt: Double?
    let isArchived: Bool?
    let pinned: Bool?
    let isPreview: Bool?
    let isLocalWorkspace: Bool?
    let isCloudWorkspace: Bool?
    let linkedFromCloudTaskRunId: ConvexId<ConvexTableTaskRuns>?
    let description: String?
    let pullRequestTitle: String?
    let pullRequestDescription: String?
    let projectFullName: String?
    let baseBranch: String?
    let worktreePath: String?
    let generatedBranchName: String?
    @OptionalConvexFloat var lastActivityAt: Double?
    let environmentId: ConvexId<ConvexTableEnvironments>?
    let crownEvaluationStatus: TasksGetByIdReturnCrownEvaluationStatusEnum?
    let crownEvaluationError: String?
    let mergeStatus: TasksGetByIdReturnMergeStatusEnum?
    let images: [TasksGetByIdReturnImagesItem]?
    let screenshotStatus: TasksGetByIdReturnScreenshotStatusEnum?
    let screenshotRunId: ConvexId<ConvexTableTaskRuns>?
    let screenshotRequestId: String?
    @OptionalConvexFloat var screenshotRequestedAt: Double?
    @OptionalConvexFloat var screenshotCompletedAt: Double?
    let screenshotError: String?
    let screenshotStorageId: ConvexId<ConvexTableStorage>?
    let screenshotMimeType: String?
    let screenshotFileName: String?
    let screenshotCommitSha: String?
    let latestScreenshotSetId: ConvexId<ConvexTableTaskRunScreenshotSets>?
    let teamId: String
    let userId: String
    let text: String
    let isCompleted: Bool
}

struct TasksGetVersionsItemFilesItem: Decodable {
    let path: String
    let changes: String
}

struct TasksGetVersionsItem: Decodable {
    let _id: ConvexId<ConvexTableTaskVersions>
    @ConvexFloat var _creationTime: Double
    let teamId: String
    @ConvexFloat var createdAt: Double
    let userId: String
    let taskId: ConvexId<ConvexTableTasks>
    let summary: String
    @ConvexFloat var version: Double
    let diff: String
    let files: [TasksGetVersionsItemFilesItem]
}

struct TasksCreateVersionArgsFilesItem: ConvexEncodable {
    let path: String
    let changes: String

    func convexEncode() throws -> String {
        var result: [String: ConvexEncodable?] = [:]
        result["path"] = path
        result["changes"] = changes
        return try result.convexEncode()
    }
}

struct TasksCreateVersionReturnTableName: Decodable {
    @ConvexFloat var length: Double
}

struct TasksCreateVersionReturn: Decodable {
    @ConvexFloat var length: Double
    let __tableName: TasksCreateVersionReturnTableName
}

struct TasksGetTasksWithPendingCrownEvaluationItemImagesItem: Decodable {
    let fileName: String?
    let storageId: ConvexId<ConvexTableStorage>
    let altText: String
}

struct TasksGetTasksWithPendingCrownEvaluationItem: Decodable {
    let _id: ConvexId<ConvexTableTasks>
    @ConvexFloat var _creationTime: Double
    @OptionalConvexFloat var createdAt: Double?
    @OptionalConvexFloat var updatedAt: Double?
    let isArchived: Bool?
    let pinned: Bool?
    let isPreview: Bool?
    let isLocalWorkspace: Bool?
    let isCloudWorkspace: Bool?
    let linkedFromCloudTaskRunId: ConvexId<ConvexTableTaskRuns>?
    let description: String?
    let pullRequestTitle: String?
    let pullRequestDescription: String?
    let projectFullName: String?
    let baseBranch: String?
    let worktreePath: String?
    let generatedBranchName: String?
    @OptionalConvexFloat var lastActivityAt: Double?
    let environmentId: ConvexId<ConvexTableEnvironments>?
    let crownEvaluationStatus: TasksGetTasksWithPendingCrownEvaluationItemCrownEvaluationStatusEnum?
    let crownEvaluationError: String?
    let mergeStatus: TasksGetTasksWithPendingCrownEvaluationItemMergeStatusEnum?
    let images: [TasksGetTasksWithPendingCrownEvaluationItemImagesItem]?
    let screenshotStatus: TasksGetTasksWithPendingCrownEvaluationItemScreenshotStatusEnum?
    let screenshotRunId: ConvexId<ConvexTableTaskRuns>?
    let screenshotRequestId: String?
    @OptionalConvexFloat var screenshotRequestedAt: Double?
    @OptionalConvexFloat var screenshotCompletedAt: Double?
    let screenshotError: String?
    let screenshotStorageId: ConvexId<ConvexTableStorage>?
    let screenshotMimeType: String?
    let screenshotFileName: String?
    let screenshotCommitSha: String?
    let latestScreenshotSetId: ConvexId<ConvexTableTaskRunScreenshotSets>?
    let teamId: String
    let userId: String
    let text: String
    let isCompleted: Bool
}

struct TasksCheckAndEvaluateCrownReturn: Decodable {
    @ConvexFloat var length: Double
}

struct TasksGetLinkedLocalWorkspaceReturnTaskImagesItem: Decodable {
    let fileName: String?
    let storageId: ConvexId<ConvexTableStorage>
    let altText: String
}

struct TasksGetLinkedLocalWorkspaceReturnTask: Decodable {
    let _id: ConvexId<ConvexTableTasks>
    @ConvexFloat var _creationTime: Double
    @OptionalConvexFloat var createdAt: Double?
    @OptionalConvexFloat var updatedAt: Double?
    let isArchived: Bool?
    let pinned: Bool?
    let isPreview: Bool?
    let isLocalWorkspace: Bool?
    let isCloudWorkspace: Bool?
    let linkedFromCloudTaskRunId: ConvexId<ConvexTableTaskRuns>?
    let description: String?
    let pullRequestTitle: String?
    let pullRequestDescription: String?
    let projectFullName: String?
    let baseBranch: String?
    let worktreePath: String?
    let generatedBranchName: String?
    @OptionalConvexFloat var lastActivityAt: Double?
    let environmentId: ConvexId<ConvexTableEnvironments>?
    let crownEvaluationStatus: TasksGetLinkedLocalWorkspaceReturnTaskCrownEvaluationStatusEnum?
    let crownEvaluationError: String?
    let mergeStatus: TasksGetLinkedLocalWorkspaceReturnTaskMergeStatusEnum?
    let images: [TasksGetLinkedLocalWorkspaceReturnTaskImagesItem]?
    let screenshotStatus: TasksGetLinkedLocalWorkspaceReturnTaskScreenshotStatusEnum?
    let screenshotRunId: ConvexId<ConvexTableTaskRuns>?
    let screenshotRequestId: String?
    @OptionalConvexFloat var screenshotRequestedAt: Double?
    @OptionalConvexFloat var screenshotCompletedAt: Double?
    let screenshotError: String?
    let screenshotStorageId: ConvexId<ConvexTableStorage>?
    let screenshotMimeType: String?
    let screenshotFileName: String?
    let screenshotCommitSha: String?
    let latestScreenshotSetId: ConvexId<ConvexTableTaskRunScreenshotSets>?
    let teamId: String
    let userId: String
    let text: String
    let isCompleted: Bool
}

struct TasksGetLinkedLocalWorkspaceReturnTaskRunEnvironmentError: Decodable {
    let devError: String?
    let maintenanceError: String?
}

struct TasksGetLinkedLocalWorkspaceReturnTaskRunPullRequestsItem: Decodable {
    @OptionalConvexFloat var number: Double?
    let url: String?
    let isDraft: Bool?
    let repoFullName: String
    let state: TasksGetLinkedLocalWorkspaceReturnTaskRunPullRequestsItemStateEnum
}

struct TasksGetLinkedLocalWorkspaceReturnTaskRunClaimsItemEvidence: Decodable {
    @OptionalConvexFloat var screenshotIndex: Double?
    let filePath: String?
    @OptionalConvexFloat var startLine: Double?
    @OptionalConvexFloat var endLine: Double?
    let type: String
}

struct TasksGetLinkedLocalWorkspaceReturnTaskRunClaimsItem: Decodable {
    let claim: String
    let evidence: TasksGetLinkedLocalWorkspaceReturnTaskRunClaimsItemEvidence
    @ConvexFloat var timestamp: Double
}

struct TasksGetLinkedLocalWorkspaceReturnTaskRunVscodePorts: Decodable {
    let `extension`: String?
    let proxy: String?
    let vnc: String?
    let vscode: String
    let worker: String
}

struct TasksGetLinkedLocalWorkspaceReturnTaskRunVscode: Decodable {
    let url: String?
    let containerName: String?
    let statusMessage: String?
    let ports: TasksGetLinkedLocalWorkspaceReturnTaskRunVscodePorts?
    let workspaceUrl: String?
    @OptionalConvexFloat var startedAt: Double?
    @OptionalConvexFloat var stoppedAt: Double?
    @OptionalConvexFloat var lastAccessedAt: Double?
    let keepAlive: Bool?
    @OptionalConvexFloat var scheduledStopAt: Double?
    let status: TasksGetLinkedLocalWorkspaceReturnTaskRunVscodeStatusEnum
    let provider: TasksGetLinkedLocalWorkspaceReturnTaskRunVscodeProviderEnum
}

struct TasksGetLinkedLocalWorkspaceReturnTaskRunNetworkingItem: Decodable {
    let status: TasksGetLinkedLocalWorkspaceReturnTaskRunNetworkingItemStatusEnum
    let url: String
    @ConvexFloat var port: Double
}

struct TasksGetLinkedLocalWorkspaceReturnTaskRunCustomPreviewsItem: Decodable {
    @ConvexFloat var createdAt: Double
    let url: String
}

struct TasksGetLinkedLocalWorkspaceReturnTaskRun: Decodable {
    let _id: ConvexId<ConvexTableTaskRuns>
    @ConvexFloat var _creationTime: Double
    let isArchived: Bool?
    let isLocalWorkspace: Bool?
    let isCloudWorkspace: Bool?
    let worktreePath: String?
    let environmentId: ConvexId<ConvexTableEnvironments>?
    let screenshotStorageId: ConvexId<ConvexTableStorage>?
    let screenshotMimeType: String?
    let screenshotFileName: String?
    let screenshotCommitSha: String?
    let latestScreenshotSetId: ConvexId<ConvexTableTaskRunScreenshotSets>?
    let parentRunId: ConvexId<ConvexTableTaskRuns>?
    let agentName: String?
    let summary: String?
    let isPreviewJob: Bool?
    let log: String?
    let newBranch: String?
    @OptionalConvexFloat var completedAt: Double?
    @OptionalConvexFloat var exitCode: Double?
    let environmentError: TasksGetLinkedLocalWorkspaceReturnTaskRunEnvironmentError?
    let errorMessage: String?
    let isCrowned: Bool?
    let crownReason: String?
    let pullRequestUrl: String?
    let pullRequestIsDraft: Bool?
    let pullRequestState: TasksGetLinkedLocalWorkspaceReturnTaskRunPullRequestStateEnum?
    @OptionalConvexFloat var pullRequestNumber: Double?
    let pullRequests: [TasksGetLinkedLocalWorkspaceReturnTaskRunPullRequestsItem]?
    @OptionalConvexFloat var diffsLastUpdated: Double?
    @OptionalConvexFloat var screenshotCapturedAt: Double?
    let claims: [TasksGetLinkedLocalWorkspaceReturnTaskRunClaimsItem]?
    @OptionalConvexFloat var claimsGeneratedAt: Double?
    let vscode: TasksGetLinkedLocalWorkspaceReturnTaskRunVscode?
    let networking: [TasksGetLinkedLocalWorkspaceReturnTaskRunNetworkingItem]?
    let customPreviews: [TasksGetLinkedLocalWorkspaceReturnTaskRunCustomPreviewsItem]?
    let teamId: String
    @ConvexFloat var createdAt: Double
    @ConvexFloat var updatedAt: Double
    let userId: String
    let taskId: ConvexId<ConvexTableTasks>
    let prompt: String
    let status: TasksGetLinkedLocalWorkspaceReturnTaskRunStatusEnum
}

struct TasksGetLinkedLocalWorkspaceReturn: Decodable {
    let task: TasksGetLinkedLocalWorkspaceReturnTask
    let taskRun: TasksGetLinkedLocalWorkspaceReturnTaskRun
}

struct TeamsGetReturn: Decodable {
    let uuid: String
    let slug: String?
    let displayName: String?
    let name: String?
}

struct TeamsListTeamMembershipsItemTeam: Decodable {
    let _id: ConvexId<ConvexTableTeams>
    @ConvexFloat var _creationTime: Double
    let slug: String?
    let displayName: String?
    let name: String?
    let profileImageUrl: String?
    let clientMetadata: String?
    let clientReadOnlyMetadata: String?
    let serverMetadata: String?
    @OptionalConvexFloat var createdAtMillis: Double?
    let teamId: String
    @ConvexFloat var createdAt: Double
    @ConvexFloat var updatedAt: Double
}

struct TeamsListTeamMembershipsItem: Decodable {
    let team: TeamsListTeamMembershipsItemTeam
    let _id: ConvexId<ConvexTableTeamMemberships>
    @ConvexFloat var _creationTime: Double
    let role: TeamsListTeamMembershipsItemRoleEnum?
    let teamId: String
    @ConvexFloat var createdAt: Double
    @ConvexFloat var updatedAt: Double
    let userId: String
}

struct TeamsSetSlugReturn: Decodable {
    let slug: String
}

struct TeamsSetNameReturn: Decodable {
    let name: String
}

struct UserEditorSettingsGetReturnSnippetsItem: Decodable {
    let name: String
    let content: String
}

struct UserEditorSettingsGetReturn: Decodable {
    let _id: ConvexId<ConvexTableUserEditorSettings>
    @ConvexFloat var _creationTime: Double
    let settingsJson: String?
    let keybindingsJson: String?
    let snippets: [UserEditorSettingsGetReturnSnippetsItem]?
    let extensions: String?
    let teamId: String
    @ConvexFloat var updatedAt: Double
    let userId: String
}

struct UserEditorSettingsUpsertArgsSnippetsItem: ConvexEncodable {
    let name: String
    let content: String

    func convexEncode() throws -> String {
        var result: [String: ConvexEncodable?] = [:]
        result["name"] = name
        result["content"] = content
        return try result.convexEncode()
    }
}

struct UserEditorSettingsUpsertReturnTableName: Decodable {
    @ConvexFloat var length: Double
}

struct UserEditorSettingsUpsertReturn: Decodable {
    @ConvexFloat var length: Double
    let __tableName: UserEditorSettingsUpsertReturnTableName
}

struct UsersGetCurrentBasicReturn: Decodable {
    let userId: String
    let displayName: String?
    let primaryEmail: String?
    let githubAccountId: String?
}

struct WorkspaceConfigsGetReturn: Decodable {
    let _id: ConvexId<ConvexTableWorkspaceConfigs>
    @ConvexFloat var _creationTime: Double
    let maintenanceScript: String?
    let dataVaultKey: String?
    let teamId: String
    @ConvexFloat var createdAt: Double
    @ConvexFloat var updatedAt: Double
    let userId: String
    let projectFullName: String
}

struct WorkspaceConfigsUpsertReturnTableName: Decodable {
    @ConvexFloat var length: Double
}

struct WorkspaceConfigsUpsertReturn: Decodable {
    @ConvexFloat var length: Double
    let __tableName: WorkspaceConfigsUpsertReturnTableName
}

struct WorkspaceSettingsGetReturnHeatmapColorsLine: Decodable {
    let start: String
    let end: String
}

struct WorkspaceSettingsGetReturnHeatmapColorsToken: Decodable {
    let start: String
    let end: String
}

struct WorkspaceSettingsGetReturnHeatmapColors: Decodable {
    let line: WorkspaceSettingsGetReturnHeatmapColorsLine
    let token: WorkspaceSettingsGetReturnHeatmapColorsToken
}

struct WorkspaceSettingsGetReturnMcpServersItemEnvItem: Decodable {
    let name: String
    let value: String
}

struct WorkspaceSettingsGetReturnMcpServersItemHeadersItem: Decodable {
    let name: String
    let value: String
}

struct WorkspaceSettingsGetReturnMcpServersItem: Decodable {
    let url: String?
    let command: String?
    let args: [String]?
    let env: [WorkspaceSettingsGetReturnMcpServersItemEnvItem]?
    let headers: [WorkspaceSettingsGetReturnMcpServersItemHeadersItem]?
    let id: String
    let name: String
    let enabled: Bool
    let transport: WorkspaceSettingsGetReturnMcpServersItemTransportEnum
}

struct WorkspaceSettingsGetReturn: Decodable {
    let _id: ConvexId<ConvexTableWorkspaceSettings>
    @ConvexFloat var _creationTime: Double
    let worktreePath: String?
    let autoPrEnabled: Bool?
    let autoSyncEnabled: Bool?
    @OptionalConvexFloat var nextLocalWorkspaceSequence: Double?
    let heatmapModel: String?
    @OptionalConvexFloat var heatmapThreshold: Double?
    let heatmapTooltipLanguage: String?
    let heatmapColors: WorkspaceSettingsGetReturnHeatmapColors?
    let conversationTitleStyle: WorkspaceSettingsGetReturnConversationTitleStyleEnum?
    let conversationTitleCustomPrompt: String?
    let acpSandboxProvider: WorkspaceSettingsGetReturnAcpSandboxProviderEnum?
    let mcpServers: [WorkspaceSettingsGetReturnMcpServersItem]?
    let teamId: String
    @ConvexFloat var createdAt: Double
    @ConvexFloat var updatedAt: Double
    let userId: String
}

struct WorkspaceSettingsUpdateArgsHeatmapColorsLine: ConvexEncodable {
    let start: String
    let end: String

    func convexEncode() throws -> String {
        var result: [String: ConvexEncodable?] = [:]
        result["start"] = start
        result["end"] = end
        return try result.convexEncode()
    }
}

struct WorkspaceSettingsUpdateArgsHeatmapColorsToken: ConvexEncodable {
    let start: String
    let end: String

    func convexEncode() throws -> String {
        var result: [String: ConvexEncodable?] = [:]
        result["start"] = start
        result["end"] = end
        return try result.convexEncode()
    }
}

struct WorkspaceSettingsUpdateArgsHeatmapColors: ConvexEncodable {
    let line: WorkspaceSettingsUpdateArgsHeatmapColorsLine
    let token: WorkspaceSettingsUpdateArgsHeatmapColorsToken

    func convexEncode() throws -> String {
        var result: [String: ConvexEncodable?] = [:]
        result["line"] = line
        result["token"] = token
        return try result.convexEncode()
    }
}

struct WorkspaceSettingsUpdateArgsMcpServersItemEnvItem: ConvexEncodable {
    let name: String
    let value: String

    func convexEncode() throws -> String {
        var result: [String: ConvexEncodable?] = [:]
        result["name"] = name
        result["value"] = value
        return try result.convexEncode()
    }
}

struct WorkspaceSettingsUpdateArgsMcpServersItemHeadersItem: ConvexEncodable {
    let name: String
    let value: String

    func convexEncode() throws -> String {
        var result: [String: ConvexEncodable?] = [:]
        result["name"] = name
        result["value"] = value
        return try result.convexEncode()
    }
}

struct WorkspaceSettingsUpdateArgsMcpServersItem: ConvexEncodable {
    let url: String?
    let command: String?
    let args: [String]?
    let env: [WorkspaceSettingsUpdateArgsMcpServersItemEnvItem]?
    let headers: [WorkspaceSettingsUpdateArgsMcpServersItemHeadersItem]?
    let id: String
    let name: String
    let enabled: Bool
    let transport: WorkspaceSettingsUpdateArgsMcpServersItemTransportEnum

    func convexEncode() throws -> String {
        var result: [String: ConvexEncodable?] = [:]
        if let value = url { result["url"] = value }
        if let value = command { result["command"] = value }
        if let value = args { result["args"] = convexEncodeArray(value) }
        if let value = env { result["env"] = convexEncodeArray(value) }
        if let value = headers { result["headers"] = convexEncodeArray(value) }
        result["id"] = id
        result["name"] = name
        result["enabled"] = enabled
        result["transport"] = transport
        return try result.convexEncode()
    }
}

struct AcpPrewarmSandboxArgs {
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct AcpStartConversationArgs {
    let clientConversationId: String?
    let sandboxId: ConvexId<ConvexTableAcpSandboxes>?
    let providerId: AcpStartConversationArgsProviderIdEnum
    let cwd: String
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = clientConversationId { result["clientConversationId"] = value }
        if let value = sandboxId { result["sandboxId"] = value }
        result["providerId"] = providerId
        result["cwd"] = cwd
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct AcpSendMessageOptimisticArgs {
    let clientConversationId: String?
    let providerId: AcpSendMessageOptimisticArgsProviderIdEnum?
    let cwd: String?
    let conversationId: ConvexId<ConvexTableConversations>?
    let clientMessageId: String?
    let content: [AcpSendMessageOptimisticArgsContentItem]
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = clientConversationId { result["clientConversationId"] = value }
        if let value = providerId { result["providerId"] = value }
        if let value = cwd { result["cwd"] = value }
        if let value = conversationId { result["conversationId"] = value }
        if let value = clientMessageId { result["clientMessageId"] = value }
        result["content"] = convexEncodeArray(content)
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct AcpSendMessageArgs {
    let clientMessageId: String?
    let content: [AcpSendMessageArgsContentItem]
    let conversationId: ConvexId<ConvexTableConversations>

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = clientMessageId { result["clientMessageId"] = value }
        result["content"] = convexEncodeArray(content)
        result["conversationId"] = conversationId
        return result
    }
}

struct AcpRetryMessageArgs {
    let conversationId: ConvexId<ConvexTableConversations>
    let messageId: ConvexId<ConvexTableConversationMessages>

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["conversationId"] = conversationId
        result["messageId"] = messageId
        return result
    }
}

struct AcpSendRpcArgs {
    let conversationId: ConvexId<ConvexTableConversations>
    let payload: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["conversationId"] = conversationId
        result["payload"] = payload
        return result
    }
}

struct AcpCancelConversationArgs {
    let conversationId: ConvexId<ConvexTableConversations>

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["conversationId"] = conversationId
        return result
    }
}

struct AcpSpawnRivetSandboxArgs {
    let teamId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["teamId"] = teamId
        return result
    }
}

struct AcpGetStreamInfoArgs {
    let conversationId: ConvexId<ConvexTableConversations>
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["conversationId"] = conversationId
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct AcpGetConversationArgs {
    let conversationId: ConvexId<ConvexTableConversations>

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["conversationId"] = conversationId
        return result
    }
}

struct AcpListMessagesArgs {
    let limit: Double?
    let cursor: String?
    let conversationId: ConvexId<ConvexTableConversations>

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = limit { result["limit"] = value }
        if let value = cursor { result["cursor"] = value }
        result["conversationId"] = conversationId
        return result
    }
}

struct AcpSubscribeNewMessagesArgs {
    let conversationId: ConvexId<ConvexTableConversations>
    let afterTimestamp: Double

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["conversationId"] = conversationId
        result["afterTimestamp"] = afterTimestamp
        return result
    }
}

struct AcpGetMessagesArgs {
    let conversationId: ConvexId<ConvexTableConversations>

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["conversationId"] = conversationId
        return result
    }
}

struct AcpRawEventsListByConversationPaginatedArgs {
    let conversationId: ConvexId<ConvexTableConversations>
    let teamSlugOrId: String
    let paginationOpts: AcpRawEventsListByConversationPaginatedArgsPaginationOpts

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["conversationId"] = conversationId
        result["teamSlugOrId"] = teamSlugOrId
        result["paginationOpts"] = paginationOpts
        return result
    }
}

struct AcpRawEventsListByConversationFirstPageArgs {
    let numItems: Double?
    let conversationId: ConvexId<ConvexTableConversations>
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = numItems { result["numItems"] = value }
        result["conversationId"] = conversationId
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct AcpSandboxesListForTeamArgs {
    let teamId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["teamId"] = teamId
        return result
    }
}

struct AcpSandboxesGetArgs {
    let sandboxId: ConvexId<ConvexTableAcpSandboxes>

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["sandboxId"] = sandboxId
        return result
    }
}

struct ApiKeysGetAllArgs {
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct ApiKeysGetByEnvVarArgs {
    let envVar: String
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["envVar"] = envVar
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct ApiKeysUpsertArgs {
    let description: String?
    let displayName: String
    let envVar: String
    let value: String
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = description { result["description"] = value }
        result["displayName"] = displayName
        result["envVar"] = envVar
        result["value"] = value
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct ApiKeysRemoveArgs {
    let envVar: String
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["envVar"] = envVar
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct ApiKeysGetAllForAgentsArgs {
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct CodeReviewReserveJobArgs {
    let prNumber: Double?
    let commitRef: String?
    let headCommitRef: String?
    let baseCommitRef: String?
    let comparison: CodeReviewReserveJobArgsComparison?
    let teamSlugOrId: String?
    let force: Bool?
    let callbackTokenHash: String
    let githubLink: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = prNumber { result["prNumber"] = value }
        if let value = commitRef { result["commitRef"] = value }
        if let value = headCommitRef { result["headCommitRef"] = value }
        if let value = baseCommitRef { result["baseCommitRef"] = value }
        if let value = comparison { result["comparison"] = value }
        if let value = teamSlugOrId { result["teamSlugOrId"] = value }
        if let value = force { result["force"] = value }
        result["callbackTokenHash"] = callbackTokenHash
        result["githubLink"] = githubLink
        return result
    }
}

struct CodeReviewMarkJobRunningArgs {
    let jobId: ConvexId<ConvexTableAutomatedCodeReviewJobs>

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["jobId"] = jobId
        return result
    }
}

struct CodeReviewFailJobArgs {
    let errorDetail: String?
    let errorCode: String
    let jobId: ConvexId<ConvexTableAutomatedCodeReviewJobs>

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = errorDetail { result["errorDetail"] = value }
        result["errorCode"] = errorCode
        result["jobId"] = jobId
        return result
    }
}

struct CodeReviewUpsertFileOutputFromCallbackArgs {
    let commitRef: String?
    let sandboxInstanceId: String?
    let tooltipLanguage: String?
    let filePath: String
    let jobId: ConvexId<ConvexTableAutomatedCodeReviewJobs>
    let codexReviewOutput: String
    let callbackToken: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = commitRef { result["commitRef"] = value }
        if let value = sandboxInstanceId { result["sandboxInstanceId"] = value }
        if let value = tooltipLanguage { result["tooltipLanguage"] = value }
        result["filePath"] = filePath
        result["jobId"] = jobId
        result["codexReviewOutput"] = codexReviewOutput
        result["callbackToken"] = callbackToken
        return result
    }
}

struct CodeReviewCompleteJobFromCallbackArgs {
    let sandboxInstanceId: String?
    let codeReviewOutput: [String: String]
    let jobId: ConvexId<ConvexTableAutomatedCodeReviewJobs>
    let callbackToken: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = sandboxInstanceId { result["sandboxInstanceId"] = value }
        result["codeReviewOutput"] = convexEncodeRecord(codeReviewOutput)
        result["jobId"] = jobId
        result["callbackToken"] = callbackToken
        return result
    }
}

struct CodeReviewFailJobFromCallbackArgs {
    let sandboxInstanceId: String?
    let errorCode: String?
    let errorDetail: String?
    let jobId: ConvexId<ConvexTableAutomatedCodeReviewJobs>
    let callbackToken: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = sandboxInstanceId { result["sandboxInstanceId"] = value }
        if let value = errorCode { result["errorCode"] = value }
        if let value = errorDetail { result["errorDetail"] = value }
        result["jobId"] = jobId
        result["callbackToken"] = callbackToken
        return result
    }
}

struct CodeReviewListFileOutputsForPrArgs {
    let commitRef: String?
    let baseCommitRef: String?
    let tooltipLanguage: String?
    let limit: Double?
    let repoFullName: String
    let prNumber: Double
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = commitRef { result["commitRef"] = value }
        if let value = baseCommitRef { result["baseCommitRef"] = value }
        if let value = tooltipLanguage { result["tooltipLanguage"] = value }
        if let value = limit { result["limit"] = value }
        result["repoFullName"] = repoFullName
        result["prNumber"] = prNumber
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct CodeReviewListFileOutputsForComparisonArgs {
    let commitRef: String?
    let baseCommitRef: String?
    let tooltipLanguage: String?
    let limit: Double?
    let repoFullName: String
    let comparisonSlug: String
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = commitRef { result["commitRef"] = value }
        if let value = baseCommitRef { result["baseCommitRef"] = value }
        if let value = tooltipLanguage { result["tooltipLanguage"] = value }
        if let value = limit { result["limit"] = value }
        result["repoFullName"] = repoFullName
        result["comparisonSlug"] = comparisonSlug
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct CodexTokensGetArgs {
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct CodexTokensSaveArgs {
    let accountId: String?
    let email: String?
    let idToken: String?
    let planType: String?
    let accessToken: String
    let refreshToken: String
    let teamSlugOrId: String
    let expiresIn: Double

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = accountId { result["accountId"] = value }
        if let value = email { result["email"] = value }
        if let value = idToken { result["idToken"] = value }
        if let value = planType { result["planType"] = value }
        result["accessToken"] = accessToken
        result["refreshToken"] = refreshToken
        result["teamSlugOrId"] = teamSlugOrId
        result["expiresIn"] = expiresIn
        return result
    }
}

struct CodexTokensRemoveArgs {
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct CommentsCreateCommentArgs {
    let profileImageUrl: String?
    let url: String
    let content: String
    let page: String
    let pageTitle: String
    let nodeId: String
    let x: Double
    let y: Double
    let userAgent: String
    let screenWidth: Double
    let screenHeight: Double
    let devicePixelRatio: Double
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = profileImageUrl { result["profileImageUrl"] = value }
        result["url"] = url
        result["content"] = content
        result["page"] = page
        result["pageTitle"] = pageTitle
        result["nodeId"] = nodeId
        result["x"] = x
        result["y"] = y
        result["userAgent"] = userAgent
        result["screenWidth"] = screenWidth
        result["screenHeight"] = screenHeight
        result["devicePixelRatio"] = devicePixelRatio
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct CommentsListCommentsArgs {
    let page: String?
    let resolved: Bool?
    let includeArchived: Bool?
    let url: String
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = page { result["page"] = value }
        if let value = resolved { result["resolved"] = value }
        if let value = includeArchived { result["includeArchived"] = value }
        result["url"] = url
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct CommentsResolveCommentArgs {
    let commentId: ConvexId<ConvexTableComments>
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["commentId"] = commentId
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct CommentsArchiveCommentArgs {
    let archived: Bool
    let commentId: ConvexId<ConvexTableComments>
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["archived"] = archived
        result["commentId"] = commentId
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct CommentsAddReplyArgs {
    let content: String
    let commentId: ConvexId<ConvexTableComments>
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["content"] = content
        result["commentId"] = commentId
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct CommentsGetRepliesArgs {
    let commentId: ConvexId<ConvexTableComments>
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["commentId"] = commentId
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct ContainerSettingsGetArgs {
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct ContainerSettingsUpdateArgs {
    let maxRunningContainers: Double?
    let reviewPeriodMinutes: Double?
    let autoCleanupEnabled: Bool?
    let stopImmediatelyOnCompletion: Bool?
    let minContainersToKeep: Double?
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = maxRunningContainers { result["maxRunningContainers"] = value }
        if let value = reviewPeriodMinutes { result["reviewPeriodMinutes"] = value }
        if let value = autoCleanupEnabled { result["autoCleanupEnabled"] = value }
        if let value = stopImmediatelyOnCompletion { result["stopImmediatelyOnCompletion"] = value }
        if let value = minContainersToKeep { result["minContainersToKeep"] = value }
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct ContainerSettingsGetEffectiveArgs {
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct ConversationMessagesListByConversationArgs {
    let limit: Double?
    let cursor: String?
    let conversationId: ConvexId<ConvexTableConversations>
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = limit { result["limit"] = value }
        if let value = cursor { result["cursor"] = value }
        result["conversationId"] = conversationId
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct ConversationMessagesListByConversationPaginatedArgs {
    let conversationId: ConversationMessagesListByConversationPaginatedArgsConversationId
    let teamSlugOrId: String
    let paginationOpts: ConversationMessagesListByConversationPaginatedArgsPaginationOpts

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["conversationId"] = conversationId
        result["teamSlugOrId"] = teamSlugOrId
        result["paginationOpts"] = paginationOpts
        return result
    }
}

struct ConversationMessagesListByConversationFirstPageArgs {
    let numItems: Double?
    let conversationId: ConversationMessagesListByConversationFirstPageArgsConversationId
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = numItems { result["numItems"] = value }
        result["conversationId"] = conversationId
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct ConversationReadsMarkReadArgs {
    let lastReadAt: Double?
    let conversationId: ConvexId<ConvexTableConversations>
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = lastReadAt { result["lastReadAt"] = value }
        result["conversationId"] = conversationId
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct ConversationReadsMarkUnreadArgs {
    let conversationId: ConvexId<ConvexTableConversations>
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["conversationId"] = conversationId
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct ConversationsCreateArgs {
    let sandboxInstanceId: String?
    let namespaceId: String?
    let isolationMode: ConversationsCreateArgsIsolationModeEnum?
    let sessionId: String
    let providerId: ConversationsCreateArgsProviderIdEnum
    let cwd: String
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = sandboxInstanceId { result["sandboxInstanceId"] = value }
        if let value = namespaceId { result["namespaceId"] = value }
        if let value = isolationMode { result["isolationMode"] = value }
        result["sessionId"] = sessionId
        result["providerId"] = providerId
        result["cwd"] = cwd
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct ConversationsGetByIdArgs {
    let conversationId: ConvexId<ConvexTableConversations>
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["conversationId"] = conversationId
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct ConversationsGetDetailArgs {
    let conversationId: ConvexId<ConvexTableConversations>
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["conversationId"] = conversationId
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct ConversationsGetBySessionIdArgs {
    let sessionId: String
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["sessionId"] = sessionId
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct ConversationsListPagedWithLatestArgs {
    let includeArchived: Bool?
    let teamSlugOrId: String
    let paginationOpts: ConversationsListPagedWithLatestArgsPaginationOpts
    let scope: ConversationsListPagedWithLatestArgsScopeEnum

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = includeArchived { result["includeArchived"] = value }
        result["teamSlugOrId"] = teamSlugOrId
        result["paginationOpts"] = paginationOpts
        result["scope"] = scope
        return result
    }
}

struct ConversationsListByNamespaceArgs {
    let namespaceId: String
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["namespaceId"] = namespaceId
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct ConversationsListBySandboxArgs {
    let sandboxInstanceId: String
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["sandboxInstanceId"] = sandboxInstanceId
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct ConversationsUpdatePermissionModeArgs {
    let permissionMode: ConversationsUpdatePermissionModeArgsPermissionModeEnum
    let conversationId: ConvexId<ConvexTableConversations>

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["permissionMode"] = permissionMode
        result["conversationId"] = conversationId
        return result
    }
}

struct ConversationsRenameArgs {
    let title: String
    let conversationId: ConvexId<ConvexTableConversations>
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["title"] = title
        result["conversationId"] = conversationId
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct ConversationsPinArgs {
    let conversationId: ConvexId<ConvexTableConversations>
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["conversationId"] = conversationId
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct ConversationsUnpinArgs {
    let conversationId: ConvexId<ConvexTableConversations>
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["conversationId"] = conversationId
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct ConversationsArchiveArgs {
    let conversationId: ConvexId<ConvexTableConversations>
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["conversationId"] = conversationId
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct ConversationsUnarchiveArgs {
    let conversationId: ConvexId<ConvexTableConversations>
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["conversationId"] = conversationId
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct ConversationsRemoveArgs {
    let conversationId: ConvexId<ConvexTableConversations>
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["conversationId"] = conversationId
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct ConversationsGetFullConversationArgs {
    let messagesLimit: Double?
    let rawEventsLimit: Double?
    let conversationId: ConvexId<ConvexTableConversations>
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = messagesLimit { result["messagesLimit"] = value }
        if let value = rawEventsLimit { result["rawEventsLimit"] = value }
        result["conversationId"] = conversationId
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct CrownEvaluateAndCrownWinnerArgs {
    let taskId: ConvexId<ConvexTableTasks>
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["taskId"] = taskId
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct CrownSetCrownWinnerArgs {
    let taskRunId: ConvexId<ConvexTableTaskRuns>
    let teamSlugOrId: String
    let reason: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["taskRunId"] = taskRunId
        result["teamSlugOrId"] = teamSlugOrId
        result["reason"] = reason
        return result
    }
}

struct CrownGetCrownedRunArgs {
    let taskId: ConvexId<ConvexTableTasks>
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["taskId"] = taskId
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct CrownGetCrownEvaluationArgs {
    let taskId: CrownGetCrownEvaluationArgsTaskId
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["taskId"] = taskId
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct CrownGetTasksWithCrownsArgs {
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct CrownActionsEvaluateArgs {
    let prompt: String
    let teamSlugOrId: String
    let candidates: [CrownActionsEvaluateArgsCandidatesItem]

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["prompt"] = prompt
        result["teamSlugOrId"] = teamSlugOrId
        result["candidates"] = convexEncodeArray(candidates)
        return result
    }
}

struct CrownActionsSummarizeArgs {
    let prompt: String
    let teamSlugOrId: String
    let gitDiff: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["prompt"] = prompt
        result["teamSlugOrId"] = teamSlugOrId
        result["gitDiff"] = gitDiff
        return result
    }
}

struct DevboxInstancesListArgs {
    let provider: DevboxInstancesListArgsProviderEnum?
    let includeStoppedAfter: Double?
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = provider { result["provider"] = value }
        if let value = includeStoppedAfter { result["includeStoppedAfter"] = value }
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct DevboxInstancesGetByIdArgs {
    let id: String
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["id"] = id
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct DevboxInstancesGetByProviderInstanceIdArgs {
    let provider: DevboxInstancesGetByProviderInstanceIdArgsProviderEnum?
    let providerInstanceId: String
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = provider { result["provider"] = value }
        result["providerInstanceId"] = providerInstanceId
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct DevboxInstancesCreateArgs {
    let name: String?
    let environmentId: ConvexId<ConvexTableEnvironments>?
    let provider: DevboxInstancesCreateArgsProviderEnum?
    let snapshotId: String?
    let source: DevboxInstancesCreateArgsSourceEnum?
    let metadata: [String: String]?
    let templateId: String?
    let vscodeUrl: String?
    let workerUrl: String?
    let vncUrl: String?
    let providerInstanceId: String
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = name { result["name"] = value }
        if let value = environmentId { result["environmentId"] = value }
        if let value = provider { result["provider"] = value }
        if let value = snapshotId { result["snapshotId"] = value }
        if let value = source { result["source"] = value }
        if let value = metadata { result["metadata"] = convexEncodeRecord(value) }
        if let value = templateId { result["templateId"] = value }
        if let value = vscodeUrl { result["vscodeUrl"] = value }
        if let value = workerUrl { result["workerUrl"] = value }
        if let value = vncUrl { result["vncUrl"] = value }
        result["providerInstanceId"] = providerInstanceId
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct DevboxInstancesUpdateStatusArgs {
    let id: String?
    let provider: DevboxInstancesUpdateStatusArgsProviderEnum?
    let providerInstanceId: String?
    let status: DevboxInstancesUpdateStatusArgsStatusEnum
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = id { result["id"] = value }
        if let value = provider { result["provider"] = value }
        if let value = providerInstanceId { result["providerInstanceId"] = value }
        result["status"] = status
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct DevboxInstancesRecordAccessArgs {
    let id: String?
    let provider: DevboxInstancesRecordAccessArgsProviderEnum?
    let providerInstanceId: String?
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = id { result["id"] = value }
        if let value = provider { result["provider"] = value }
        if let value = providerInstanceId { result["providerInstanceId"] = value }
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct DevboxInstancesRemoveArgs {
    let id: String
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["id"] = id
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct E2bInstancesGetActivityArgs {
    let instanceId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["instanceId"] = instanceId
        return result
    }
}

struct E2bInstancesRecordResumeArgs {
    let instanceId: String
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["instanceId"] = instanceId
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct EnvironmentSnapshotsListArgs {
    let environmentId: ConvexId<ConvexTableEnvironments>
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["environmentId"] = environmentId
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct EnvironmentSnapshotsCreateArgs {
    let maintenanceScript: String?
    let devScript: String?
    let label: String?
    let activate: Bool?
    let environmentId: ConvexId<ConvexTableEnvironments>
    let morphSnapshotId: String
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = maintenanceScript { result["maintenanceScript"] = value }
        if let value = devScript { result["devScript"] = value }
        if let value = label { result["label"] = value }
        if let value = activate { result["activate"] = value }
        result["environmentId"] = environmentId
        result["morphSnapshotId"] = morphSnapshotId
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct EnvironmentSnapshotsActivateArgs {
    let environmentId: ConvexId<ConvexTableEnvironments>
    let teamSlugOrId: String
    let snapshotVersionId: ConvexId<ConvexTableEnvironmentSnapshotVersions>

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["environmentId"] = environmentId
        result["teamSlugOrId"] = teamSlugOrId
        result["snapshotVersionId"] = snapshotVersionId
        return result
    }
}

struct EnvironmentSnapshotsRemoveArgs {
    let environmentId: ConvexId<ConvexTableEnvironments>
    let teamSlugOrId: String
    let snapshotVersionId: ConvexId<ConvexTableEnvironmentSnapshotVersions>

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["environmentId"] = environmentId
        result["teamSlugOrId"] = teamSlugOrId
        result["snapshotVersionId"] = snapshotVersionId
        return result
    }
}

struct EnvironmentSnapshotsFindBySnapshotIdArgs {
    let snapshotId: String
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["snapshotId"] = snapshotId
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct EnvironmentsListArgs {
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct EnvironmentsGetArgs {
    let id: ConvexId<ConvexTableEnvironments>
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["id"] = id
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct EnvironmentsCreateArgs {
    let description: String?
    let maintenanceScript: String?
    let selectedRepos: [String]?
    let devScript: String?
    let exposedPorts: [Double]?
    let name: String
    let dataVaultKey: String
    let morphSnapshotId: String
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = description { result["description"] = value }
        if let value = maintenanceScript { result["maintenanceScript"] = value }
        if let value = selectedRepos { result["selectedRepos"] = convexEncodeArray(value) }
        if let value = devScript { result["devScript"] = value }
        if let value = exposedPorts { result["exposedPorts"] = convexEncodeArray(value) }
        result["name"] = name
        result["dataVaultKey"] = dataVaultKey
        result["morphSnapshotId"] = morphSnapshotId
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct EnvironmentsUpdateArgs {
    let name: String?
    let description: String?
    let maintenanceScript: String?
    let devScript: String?
    let id: ConvexId<ConvexTableEnvironments>
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = name { result["name"] = value }
        if let value = description { result["description"] = value }
        if let value = maintenanceScript { result["maintenanceScript"] = value }
        if let value = devScript { result["devScript"] = value }
        result["id"] = id
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct EnvironmentsUpdateExposedPortsArgs {
    let id: ConvexId<ConvexTableEnvironments>
    let ports: [Double]
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["id"] = id
        result["ports"] = convexEncodeArray(ports)
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct EnvironmentsRemoveArgs {
    let id: ConvexId<ConvexTableEnvironments>
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["id"] = id
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct EnvironmentsGetByDataVaultKeyArgs {
    let dataVaultKey: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["dataVaultKey"] = dataVaultKey
        return result
    }
}

struct GithubGetReposByOrgArgs {
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct GithubGetBranchesArgs {
    let repo: String
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["repo"] = repo
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct GithubGetRepoByFullNameArgs {
    let fullName: String
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["fullName"] = fullName
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct GithubGetAllReposArgs {
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct GithubGetReposByInstallationArgs {
    let installationId: Double
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["installationId"] = installationId
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct GithubGetBranchesByRepoArgs {
    let repo: String
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["repo"] = repo
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct GithubHasReposForTeamArgs {
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct GithubListProviderConnectionsArgs {
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct GithubListUnassignedProviderConnectionsArgs {
    // Unsupported args shape
}

struct GithubAssignProviderConnectionToTeamArgs {
    let installationId: Double
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["installationId"] = installationId
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct GithubRemoveProviderConnectionArgs {
    let installationId: Double
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["installationId"] = installationId
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct GithubUpsertRepoArgs {
    let provider: String?
    let name: String
    let fullName: String
    let org: String
    let gitRemote: String
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = provider { result["provider"] = value }
        result["name"] = name
        result["fullName"] = fullName
        result["org"] = org
        result["gitRemote"] = gitRemote
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct GithubBulkInsertReposArgs {
    let repos: [GithubBulkInsertReposArgsReposItem]
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["repos"] = convexEncodeArray(repos)
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct GithubBulkInsertBranchesArgs {
    let repo: String
    let branches: [String]
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["repo"] = repo
        result["branches"] = convexEncodeArray(branches)
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct GithubBulkUpsertBranchesWithActivityArgs {
    let repo: String
    let branches: [GithubBulkUpsertBranchesWithActivityArgsBranchesItem]
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["repo"] = repo
        result["branches"] = convexEncodeArray(branches)
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct GithubReplaceAllReposArgs {
    let repos: [GithubReplaceAllReposArgsReposItem]
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["repos"] = convexEncodeArray(repos)
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct GithubAppMintInstallStateArgs {
    let returnUrl: String?
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = returnUrl { result["returnUrl"] = value }
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct GithubCheckRunsGetCheckRunsForPrArgs {
    let headSha: String?
    let limit: Double?
    let repoFullName: String
    let prNumber: Double
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = headSha { result["headSha"] = value }
        if let value = limit { result["limit"] = value }
        result["repoFullName"] = repoFullName
        result["prNumber"] = prNumber
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct GithubCommitStatusesGetCommitStatusesForPrArgs {
    let headSha: String?
    let limit: Double?
    let repoFullName: String
    let prNumber: Double
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = headSha { result["headSha"] = value }
        if let value = limit { result["limit"] = value }
        result["repoFullName"] = repoFullName
        result["prNumber"] = prNumber
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct GithubDeploymentsGetDeploymentsForPrArgs {
    let headSha: String?
    let limit: Double?
    let repoFullName: String
    let prNumber: Double
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = headSha { result["headSha"] = value }
        if let value = limit { result["limit"] = value }
        result["repoFullName"] = repoFullName
        result["prNumber"] = prNumber
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct GithubHttpAddManualRepoArgs {
    let repoUrl: String
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["repoUrl"] = repoUrl
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct GithubPrsListPullRequestsArgs {
    let state: GithubPrsListPullRequestsArgsStateEnum?
    let limit: Double?
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = state { result["state"] = value }
        if let value = limit { result["limit"] = value }
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct GithubPrsGetPullRequestArgs {
    let number: Double
    let repoFullName: String
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["number"] = number
        result["repoFullName"] = repoFullName
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct GithubPrsUpsertFromServerArgs {
    let number: Double
    let record: GithubPrsUpsertFromServerArgsRecord
    let repoFullName: String
    let installationId: Double
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["number"] = number
        result["record"] = record
        result["repoFullName"] = repoFullName
        result["installationId"] = installationId
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct GithubWorkflowsGetWorkflowRunsArgs {
    let repoFullName: String?
    let workflowId: Double?
    let limit: Double?
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = repoFullName { result["repoFullName"] = value }
        if let value = workflowId { result["workflowId"] = value }
        if let value = limit { result["limit"] = value }
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct GithubWorkflowsGetWorkflowRunByIdArgs {
    let runId: Double
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["runId"] = runId
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct GithubWorkflowsGetWorkflowRunsForPrArgs {
    let headSha: String?
    let limit: Double?
    let repoFullName: String
    let prNumber: Double
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = headSha { result["headSha"] = value }
        if let value = limit { result["limit"] = value }
        result["repoFullName"] = repoFullName
        result["prNumber"] = prNumber
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct HostScreenshotCollectorGetLatestReleaseUrlArgs {
    let isStaging: Bool

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["isStaging"] = isStaging
        return result
    }
}

struct HostScreenshotCollectorListReleasesArgs {
    let limit: Double?
    let isStaging: Bool

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = limit { result["limit"] = value }
        result["isStaging"] = isStaging
        return result
    }
}

struct HostScreenshotCollectorActionsSyncReleaseArgs {
    let releaseUrl: String?
    let commitSha: String
    let version: String
    let isStaging: Bool
    let fileContent: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = releaseUrl { result["releaseUrl"] = value }
        result["commitSha"] = commitSha
        result["version"] = version
        result["isStaging"] = isStaging
        result["fileContent"] = fileContent
        return result
    }
}

struct LocalWorkspacesNextSequenceArgs {
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct LocalWorkspacesReserveArgs {
    let linkedFromCloudTaskRunId: ConvexId<ConvexTableTaskRuns>?
    let projectFullName: String?
    let repoUrl: String?
    let branch: String?
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = linkedFromCloudTaskRunId { result["linkedFromCloudTaskRunId"] = value }
        if let value = projectFullName { result["projectFullName"] = value }
        if let value = repoUrl { result["repoUrl"] = value }
        if let value = branch { result["branch"] = value }
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct MorphInstancesGetActivityArgs {
    let instanceId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["instanceId"] = instanceId
        return result
    }
}

struct MorphInstancesRecordResumeArgs {
    let instanceId: String
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["instanceId"] = instanceId
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct PreviewConfigsListByTeamArgs {
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct PreviewConfigsGetArgs {
    let previewConfigId: ConvexId<ConvexTablePreviewConfigs>
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["previewConfigId"] = previewConfigId
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct PreviewConfigsGetByRepoArgs {
    let repoFullName: String
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["repoFullName"] = repoFullName
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct PreviewConfigsRemoveArgs {
    let previewConfigId: ConvexId<ConvexTablePreviewConfigs>
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["previewConfigId"] = previewConfigId
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct PreviewConfigsUpsertArgs {
    let environmentId: ConvexId<ConvexTableEnvironments>?
    let status: PreviewConfigsUpsertArgsStatusEnum?
    let repoInstallationId: Double?
    let repoDefaultBranch: String?
    let repoFullName: String
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = environmentId { result["environmentId"] = value }
        if let value = status { result["status"] = value }
        if let value = repoInstallationId { result["repoInstallationId"] = value }
        if let value = repoDefaultBranch { result["repoDefaultBranch"] = value }
        result["repoFullName"] = repoFullName
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct PreviewRunsListByConfigArgs {
    let limit: Double?
    let previewConfigId: ConvexId<ConvexTablePreviewConfigs>
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = limit { result["limit"] = value }
        result["previewConfigId"] = previewConfigId
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct PreviewRunsListByTeamArgs {
    let limit: Double?
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = limit { result["limit"] = value }
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct PreviewRunsListByTeamPaginatedArgs {
    let teamSlugOrId: String
    let paginationOpts: PreviewRunsListByTeamPaginatedArgsPaginationOpts

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["teamSlugOrId"] = teamSlugOrId
        result["paginationOpts"] = paginationOpts
        return result
    }
}

struct PreviewRunsCreateManualArgs {
    let prTitle: String?
    let prDescription: String?
    let baseSha: String?
    let headRef: String?
    let repoFullName: String
    let prNumber: Double
    let prUrl: String
    let headSha: String
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = prTitle { result["prTitle"] = value }
        if let value = prDescription { result["prDescription"] = value }
        if let value = baseSha { result["baseSha"] = value }
        if let value = headRef { result["headRef"] = value }
        result["repoFullName"] = repoFullName
        result["prNumber"] = prNumber
        result["prUrl"] = prUrl
        result["headSha"] = headSha
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct PreviewScreenshotsUploadAndCommentArgs {
    let error: String?
    let images: [PreviewScreenshotsUploadAndCommentArgsImagesItem]?
    let hasUiChanges: Bool?
    let videos: [PreviewScreenshotsUploadAndCommentArgsVideosItem]?
    let status: PreviewScreenshotsUploadAndCommentArgsStatusEnum
    let commitSha: String
    let previewRunId: ConvexId<ConvexTablePreviewRuns>

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = error { result["error"] = value }
        if let value = images { result["images"] = convexEncodeArray(value) }
        if let value = hasUiChanges { result["hasUiChanges"] = value }
        if let value = videos { result["videos"] = convexEncodeArray(value) }
        result["status"] = status
        result["commitSha"] = commitSha
        result["previewRunId"] = previewRunId
        return result
    }
}

struct PreviewTestJobsCreateTestRunArgs {
    let prMetadata: PreviewTestJobsCreateTestRunArgsPrMetadata?
    let prUrl: String
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = prMetadata { result["prMetadata"] = value }
        result["prUrl"] = prUrl
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct PreviewTestJobsDispatchTestJobArgs {
    let teamSlugOrId: String
    let previewRunId: ConvexId<ConvexTablePreviewRuns>

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["teamSlugOrId"] = teamSlugOrId
        result["previewRunId"] = previewRunId
        return result
    }
}

struct PreviewTestJobsListTestRunsArgs {
    let limit: Double?
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = limit { result["limit"] = value }
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct PreviewTestJobsGetTestRunDetailsArgs {
    let teamSlugOrId: String
    let previewRunId: ConvexId<ConvexTablePreviewRuns>

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["teamSlugOrId"] = teamSlugOrId
        result["previewRunId"] = previewRunId
        return result
    }
}

struct PreviewTestJobsCheckRepoAccessArgs {
    let prUrl: String
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["prUrl"] = prUrl
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct PreviewTestJobsRetryTestJobArgs {
    let teamSlugOrId: String
    let previewRunId: ConvexId<ConvexTablePreviewRuns>

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["teamSlugOrId"] = teamSlugOrId
        result["previewRunId"] = previewRunId
        return result
    }
}

struct PreviewTestJobsDeleteTestRunArgs {
    let teamSlugOrId: String
    let previewRunId: ConvexId<ConvexTablePreviewRuns>

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["teamSlugOrId"] = teamSlugOrId
        result["previewRunId"] = previewRunId
        return result
    }
}

struct PushTokensUpsertArgs {
    let deviceId: String?
    let token: String
    let environment: PushTokensUpsertArgsEnvironmentEnum
    let platform: String
    let bundleId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = deviceId { result["deviceId"] = value }
        result["token"] = token
        result["environment"] = environment
        result["platform"] = platform
        result["bundleId"] = bundleId
        return result
    }
}

struct PushTokensRemoveArgs {
    let token: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["token"] = token
        return result
    }
}

struct PushTokensSendTestArgs {
    let title: String?
    let body: String?

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = title { result["title"] = value }
        if let value = body { result["body"] = value }
        return result
    }
}

struct StackUpsertUserPublicArgs {
    let displayName: String?
    let profileImageUrl: String?
    let clientMetadata: String?
    let clientReadOnlyMetadata: String?
    let serverMetadata: String?
    let primaryEmail: String?
    let selectedTeamId: String?
    let selectedTeamDisplayName: String?
    let selectedTeamProfileImageUrl: String?
    let oauthProviders: [StackUpsertUserPublicArgsOauthProvidersItem]?
    let id: String
    let primaryEmailVerified: Bool
    let primaryEmailAuthEnabled: Bool
    let hasPassword: Bool
    let otpAuthEnabled: Bool
    let passkeyAuthEnabled: Bool
    let signedUpAtMillis: Double
    let lastActiveAtMillis: Double
    let isAnonymous: Bool

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = displayName { result["displayName"] = value }
        if let value = profileImageUrl { result["profileImageUrl"] = value }
        if let value = clientMetadata { result["clientMetadata"] = value }
        if let value = clientReadOnlyMetadata { result["clientReadOnlyMetadata"] = value }
        if let value = serverMetadata { result["serverMetadata"] = value }
        if let value = primaryEmail { result["primaryEmail"] = value }
        if let value = selectedTeamId { result["selectedTeamId"] = value }
        if let value = selectedTeamDisplayName { result["selectedTeamDisplayName"] = value }
        if let value = selectedTeamProfileImageUrl { result["selectedTeamProfileImageUrl"] = value }
        if let value = oauthProviders { result["oauthProviders"] = convexEncodeArray(value) }
        result["id"] = id
        result["primaryEmailVerified"] = primaryEmailVerified
        result["primaryEmailAuthEnabled"] = primaryEmailAuthEnabled
        result["hasPassword"] = hasPassword
        result["otpAuthEnabled"] = otpAuthEnabled
        result["passkeyAuthEnabled"] = passkeyAuthEnabled
        result["signedUpAtMillis"] = signedUpAtMillis
        result["lastActiveAtMillis"] = lastActiveAtMillis
        result["isAnonymous"] = isAnonymous
        return result
    }
}

struct StackDeleteUserPublicArgs {
    let id: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["id"] = id
        return result
    }
}

struct StackUpsertTeamPublicArgs {
    let displayName: String?
    let profileImageUrl: String?
    let clientMetadata: String?
    let clientReadOnlyMetadata: String?
    let serverMetadata: String?
    let id: String
    let createdAtMillis: Double

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = displayName { result["displayName"] = value }
        if let value = profileImageUrl { result["profileImageUrl"] = value }
        if let value = clientMetadata { result["clientMetadata"] = value }
        if let value = clientReadOnlyMetadata { result["clientReadOnlyMetadata"] = value }
        if let value = serverMetadata { result["serverMetadata"] = value }
        result["id"] = id
        result["createdAtMillis"] = createdAtMillis
        return result
    }
}

struct StackDeleteTeamPublicArgs {
    let id: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["id"] = id
        return result
    }
}

struct StackEnsureMembershipPublicArgs {
    let teamId: String
    let userId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["teamId"] = teamId
        result["userId"] = userId
        return result
    }
}

struct StackDeleteMembershipPublicArgs {
    let teamId: String
    let userId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["teamId"] = teamId
        result["userId"] = userId
        return result
    }
}

struct StackEnsurePermissionPublicArgs {
    let teamId: String
    let userId: String
    let permissionId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["teamId"] = teamId
        result["userId"] = userId
        result["permissionId"] = permissionId
        return result
    }
}

struct StackDeletePermissionPublicArgs {
    let teamId: String
    let userId: String
    let permissionId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["teamId"] = teamId
        result["userId"] = userId
        result["permissionId"] = permissionId
        return result
    }
}

struct StorageGenerateUploadUrlArgs {
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct StorageGetUrlArgs {
    let storageId: ConvexId<ConvexTableStorage>
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["storageId"] = storageId
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct StorageGetUrlsArgs {
    let teamSlugOrId: String
    let storageIds: [ConvexId<ConvexTableStorage>]

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["teamSlugOrId"] = teamSlugOrId
        result["storageIds"] = convexEncodeArray(storageIds)
        return result
    }
}

struct TaskCommentsListByTaskArgs {
    let taskId: ConvexId<ConvexTableTasks>
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["taskId"] = taskId
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TaskCommentsCreateForTaskArgs {
    let taskId: ConvexId<ConvexTableTasks>
    let content: String
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["taskId"] = taskId
        result["content"] = content
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TaskCommentsCreateSystemForTaskArgs {
    let taskId: ConvexId<ConvexTableTasks>
    let content: String
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["taskId"] = taskId
        result["content"] = content
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TaskCommentsLatestSystemByTaskArgs {
    let taskId: ConvexId<ConvexTableTasks>
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["taskId"] = taskId
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TaskNotificationsListArgs {
    let limit: Double?
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = limit { result["limit"] = value }
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TaskNotificationsHasUnreadForTaskArgs {
    let taskId: ConvexId<ConvexTableTasks>
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["taskId"] = taskId
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TaskNotificationsGetUnreadCountArgs {
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TaskNotificationsGetTasksWithUnreadArgs {
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TaskNotificationsMarkTaskRunAsReadArgs {
    let taskRunId: ConvexId<ConvexTableTaskRuns>
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["taskRunId"] = taskRunId
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TaskNotificationsMarkTaskRunAsUnreadArgs {
    let taskRunId: ConvexId<ConvexTableTaskRuns>
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["taskRunId"] = taskRunId
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TaskNotificationsMarkTaskAsReadArgs {
    let taskId: ConvexId<ConvexTableTasks>
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["taskId"] = taskId
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TaskNotificationsMarkTaskAsUnreadArgs {
    let taskId: ConvexId<ConvexTableTasks>
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["taskId"] = taskId
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TaskNotificationsMarkAllAsReadArgs {
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TaskRunLogChunksAppendChunkArgs {
    let taskRunId: ConvexId<ConvexTableTaskRuns>
    let content: String
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["taskRunId"] = taskRunId
        result["content"] = content
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TaskRunLogChunksAppendChunkPublicArgs {
    let taskRunId: ConvexId<ConvexTableTaskRuns>
    let content: String
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["taskRunId"] = taskRunId
        result["content"] = content
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TaskRunLogChunksGetChunksArgs {
    let taskRunId: ConvexId<ConvexTableTaskRuns>
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["taskRunId"] = taskRunId
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TaskRunsCreateArgs {
    let environmentId: ConvexId<ConvexTableEnvironments>?
    let parentRunId: ConvexId<ConvexTableTaskRuns>?
    let agentName: String?
    let newBranch: String?
    let taskId: ConvexId<ConvexTableTasks>
    let prompt: String
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = environmentId { result["environmentId"] = value }
        if let value = parentRunId { result["parentRunId"] = value }
        if let value = agentName { result["agentName"] = value }
        if let value = newBranch { result["newBranch"] = value }
        result["taskId"] = taskId
        result["prompt"] = prompt
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TaskRunsGetByTaskArgs {
    let includeArchived: Bool?
    let taskId: TaskRunsGetByTaskArgsTaskId
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = includeArchived { result["includeArchived"] = value }
        result["taskId"] = taskId
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TaskRunsGetRunDiffContextArgs {
    let taskId: ConvexId<ConvexTableTasks>
    let runId: ConvexId<ConvexTableTaskRuns>
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["taskId"] = taskId
        result["runId"] = runId
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TaskRunsUpdateSummaryArgs {
    let id: ConvexId<ConvexTableTaskRuns>
    let summary: String
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["id"] = id
        result["summary"] = summary
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TaskRunsGetArgs {
    let id: ConvexId<ConvexTableTaskRuns>
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["id"] = id
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TaskRunsSubscribeArgs {
    let id: ConvexId<ConvexTableTaskRuns>
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["id"] = id
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TaskRunsUpdateWorktreePathArgs {
    let id: ConvexId<ConvexTableTaskRuns>
    let worktreePath: String
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["id"] = id
        result["worktreePath"] = worktreePath
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TaskRunsUpdateBranchArgs {
    let id: ConvexId<ConvexTableTaskRuns>
    let newBranch: String
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["id"] = id
        result["newBranch"] = newBranch
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TaskRunsUpdateBranchBatchArgs {
    let teamSlugOrId: String
    let updates: [TaskRunsUpdateBranchBatchArgsUpdatesItem]

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["teamSlugOrId"] = teamSlugOrId
        result["updates"] = convexEncodeArray(updates)
        return result
    }
}

struct TaskRunsGetJwtArgs {
    let taskRunId: ConvexId<ConvexTableTaskRuns>
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["taskRunId"] = taskRunId
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TaskRunsUpdateStatusPublicArgs {
    let exitCode: Double?
    let id: ConvexId<ConvexTableTaskRuns>
    let status: TaskRunsUpdateStatusPublicArgsStatusEnum
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = exitCode { result["exitCode"] = value }
        result["id"] = id
        result["status"] = status
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TaskRunsUpdateVSCodeInstanceArgs {
    let id: ConvexId<ConvexTableTaskRuns>
    let vscode: TaskRunsUpdateVSCodeInstanceArgsVscode
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["id"] = id
        result["vscode"] = vscode
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TaskRunsUpdateVSCodeStatusArgs {
    let stoppedAt: Double?
    let id: ConvexId<ConvexTableTaskRuns>
    let status: TaskRunsUpdateVSCodeStatusArgsStatusEnum
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = stoppedAt { result["stoppedAt"] = value }
        result["id"] = id
        result["status"] = status
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TaskRunsUpdateVSCodePortsArgs {
    let id: ConvexId<ConvexTableTaskRuns>
    let ports: TaskRunsUpdateVSCodePortsArgsPorts
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["id"] = id
        result["ports"] = ports
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TaskRunsUpdateVSCodeStatusMessageArgs {
    let statusMessage: String?
    let id: ConvexId<ConvexTableTaskRuns>
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = statusMessage { result["statusMessage"] = value }
        result["id"] = id
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TaskRunsGetByContainerNameArgs {
    let containerName: String
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["containerName"] = containerName
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TaskRunsCompleteArgs {
    let exitCode: Double?
    let id: ConvexId<ConvexTableTaskRuns>
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = exitCode { result["exitCode"] = value }
        result["id"] = id
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TaskRunsFailArgs {
    let exitCode: Double?
    let id: ConvexId<ConvexTableTaskRuns>
    let errorMessage: String
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = exitCode { result["exitCode"] = value }
        result["id"] = id
        result["errorMessage"] = errorMessage
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TaskRunsAddCustomPreviewArgs {
    let url: String
    let runId: ConvexId<ConvexTableTaskRuns>
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["url"] = url
        result["runId"] = runId
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TaskRunsRemoveCustomPreviewArgs {
    let index: Double
    let runId: ConvexId<ConvexTableTaskRuns>
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["index"] = index
        result["runId"] = runId
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TaskRunsUpdateCustomPreviewUrlArgs {
    let index: Double
    let url: String
    let runId: ConvexId<ConvexTableTaskRuns>
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["index"] = index
        result["url"] = url
        result["runId"] = runId
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TaskRunsGetActiveVSCodeInstancesArgs {
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TaskRunsUpdateLastAccessedArgs {
    let id: ConvexId<ConvexTableTaskRuns>
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["id"] = id
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TaskRunsToggleKeepAliveArgs {
    let id: ConvexId<ConvexTableTaskRuns>
    let keepAlive: Bool
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["id"] = id
        result["keepAlive"] = keepAlive
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TaskRunsUpdatePullRequestUrlArgs {
    let number: Double?
    let pullRequests: [TaskRunsUpdatePullRequestUrlArgsPullRequestsItem]?
    let state: TaskRunsUpdatePullRequestUrlArgsStateEnum?
    let isDraft: Bool?
    let id: ConvexId<ConvexTableTaskRuns>
    let pullRequestUrl: String
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = number { result["number"] = value }
        if let value = pullRequests { result["pullRequests"] = convexEncodeArray(value) }
        if let value = state { result["state"] = value }
        if let value = isDraft { result["isDraft"] = value }
        result["id"] = id
        result["pullRequestUrl"] = pullRequestUrl
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TaskRunsUpdatePullRequestStateArgs {
    let number: Double?
    let pullRequests: [TaskRunsUpdatePullRequestStateArgsPullRequestsItem]?
    let url: String?
    let isDraft: Bool?
    let id: ConvexId<ConvexTableTaskRuns>
    let state: TaskRunsUpdatePullRequestStateArgsStateEnum
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = number { result["number"] = value }
        if let value = pullRequests { result["pullRequests"] = convexEncodeArray(value) }
        if let value = url { result["url"] = value }
        if let value = isDraft { result["isDraft"] = value }
        result["id"] = id
        result["state"] = state
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TaskRunsUpdateNetworkingArgs {
    let id: ConvexId<ConvexTableTaskRuns>
    let networking: [TaskRunsUpdateNetworkingArgsNetworkingItem]
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["id"] = id
        result["networking"] = convexEncodeArray(networking)
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TaskRunsUpdateEnvironmentErrorArgs {
    let devError: String?
    let maintenanceError: String?
    let id: ConvexId<ConvexTableTaskRuns>
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = devError { result["devError"] = value }
        if let value = maintenanceError { result["maintenanceError"] = value }
        result["id"] = id
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TaskRunsArchiveArgs {
    let taskId: ConvexId<ConvexTableTasks>?
    let includeChildren: Bool?
    let id: ConvexId<ConvexTableTaskRuns>
    let teamSlugOrId: String
    let archive: Bool

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = taskId { result["taskId"] = value }
        if let value = includeChildren { result["includeChildren"] = value }
        result["id"] = id
        result["teamSlugOrId"] = teamSlugOrId
        result["archive"] = archive
        return result
    }
}

struct TaskRunsGetContainersToStopArgs {
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TaskRunsGetRunningContainersByCleanupPriorityArgs {
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TasksGetArgs {
    let projectFullName: String?
    let archived: Bool?
    let excludeLocalWorkspaces: Bool?
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = projectFullName { result["projectFullName"] = value }
        if let value = archived { result["archived"] = value }
        if let value = excludeLocalWorkspaces { result["excludeLocalWorkspaces"] = value }
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TasksGetArchivedPaginatedArgs {
    let excludeLocalWorkspaces: Bool?
    let teamSlugOrId: String
    let paginationOpts: TasksGetArchivedPaginatedArgsPaginationOpts

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = excludeLocalWorkspaces { result["excludeLocalWorkspaces"] = value }
        result["teamSlugOrId"] = teamSlugOrId
        result["paginationOpts"] = paginationOpts
        return result
    }
}

struct TasksGetWithNotificationOrderArgs {
    let projectFullName: String?
    let archived: Bool?
    let excludeLocalWorkspaces: Bool?
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = projectFullName { result["projectFullName"] = value }
        if let value = archived { result["archived"] = value }
        if let value = excludeLocalWorkspaces { result["excludeLocalWorkspaces"] = value }
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TasksGetPreviewTasksArgs {
    let limit: Double?
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = limit { result["limit"] = value }
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TasksGetPinnedArgs {
    let excludeLocalWorkspaces: Bool?
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = excludeLocalWorkspaces { result["excludeLocalWorkspaces"] = value }
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TasksGetTasksWithTaskRunsArgs {
    let projectFullName: String?
    let archived: Bool?
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = projectFullName { result["projectFullName"] = value }
        if let value = archived { result["archived"] = value }
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TasksCreateArgs {
    let isCloudWorkspace: Bool?
    let description: String?
    let projectFullName: String?
    let baseBranch: String?
    let worktreePath: String?
    let environmentId: ConvexId<ConvexTableEnvironments>?
    let images: [TasksCreateArgsImagesItem]?
    let selectedAgents: [String]?
    let text: String
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = isCloudWorkspace { result["isCloudWorkspace"] = value }
        if let value = description { result["description"] = value }
        if let value = projectFullName { result["projectFullName"] = value }
        if let value = baseBranch { result["baseBranch"] = value }
        if let value = worktreePath { result["worktreePath"] = value }
        if let value = environmentId { result["environmentId"] = value }
        if let value = images { result["images"] = convexEncodeArray(value) }
        if let value = selectedAgents { result["selectedAgents"] = convexEncodeArray(value) }
        result["text"] = text
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TasksRemoveArgs {
    let id: ConvexId<ConvexTableTasks>
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["id"] = id
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TasksToggleArgs {
    let id: ConvexId<ConvexTableTasks>
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["id"] = id
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TasksSetCompletedArgs {
    let id: ConvexId<ConvexTableTasks>
    let isCompleted: Bool
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["id"] = id
        result["isCompleted"] = isCompleted
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TasksUpdateArgs {
    let id: ConvexId<ConvexTableTasks>
    let text: String
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["id"] = id
        result["text"] = text
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TasksUpdateWorktreePathArgs {
    let id: ConvexId<ConvexTableTasks>
    let worktreePath: String
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["id"] = id
        result["worktreePath"] = worktreePath
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TasksGetByIdArgs {
    let id: TasksGetByIdArgsId
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["id"] = id
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TasksGetVersionsArgs {
    let taskId: ConvexId<ConvexTableTasks>
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["taskId"] = taskId
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TasksArchiveArgs {
    let id: ConvexId<ConvexTableTasks>
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["id"] = id
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TasksUnarchiveArgs {
    let id: ConvexId<ConvexTableTasks>
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["id"] = id
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TasksPinArgs {
    let id: ConvexId<ConvexTableTasks>
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["id"] = id
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TasksUnpinArgs {
    let id: ConvexId<ConvexTableTasks>
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["id"] = id
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TasksUpdateCrownErrorArgs {
    let crownEvaluationStatus: TasksUpdateCrownErrorArgsCrownEvaluationStatusEnum?
    let crownEvaluationError: String?
    let id: ConvexId<ConvexTableTasks>
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = crownEvaluationStatus { result["crownEvaluationStatus"] = value }
        if let value = crownEvaluationError { result["crownEvaluationError"] = value }
        result["id"] = id
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TasksTryBeginCrownEvaluationArgs {
    let id: ConvexId<ConvexTableTasks>
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["id"] = id
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TasksSetPullRequestDescriptionArgs {
    let pullRequestDescription: String?
    let id: ConvexId<ConvexTableTasks>
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = pullRequestDescription { result["pullRequestDescription"] = value }
        result["id"] = id
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TasksSetPullRequestTitleArgs {
    let pullRequestTitle: String?
    let id: ConvexId<ConvexTableTasks>
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = pullRequestTitle { result["pullRequestTitle"] = value }
        result["id"] = id
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TasksCreateVersionArgs {
    let taskId: ConvexId<ConvexTableTasks>
    let summary: String
    let diff: String
    let files: [TasksCreateVersionArgsFilesItem]
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["taskId"] = taskId
        result["summary"] = summary
        result["diff"] = diff
        result["files"] = convexEncodeArray(files)
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TasksGetTasksWithPendingCrownEvaluationArgs {
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TasksUpdateMergeStatusArgs {
    let id: ConvexId<ConvexTableTasks>
    let mergeStatus: TasksUpdateMergeStatusArgsMergeStatusEnum
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["id"] = id
        result["mergeStatus"] = mergeStatus
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TasksCheckAndEvaluateCrownArgs {
    let taskId: ConvexId<ConvexTableTasks>
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["taskId"] = taskId
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TasksGetLinkedLocalWorkspaceArgs {
    let teamSlugOrId: String
    let cloudTaskRunId: ConvexId<ConvexTableTaskRuns>

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["teamSlugOrId"] = teamSlugOrId
        result["cloudTaskRunId"] = cloudTaskRunId
        return result
    }
}

struct TeamsGetArgs {
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TeamsListTeamMembershipsArgs {
    // Unsupported args shape
}

struct TeamsSetSlugArgs {
    let slug: String
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["slug"] = slug
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct TeamsSetNameArgs {
    let name: String
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["name"] = name
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct UserEditorSettingsGetArgs {
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct UserEditorSettingsUpsertArgs {
    let settingsJson: String?
    let keybindingsJson: String?
    let snippets: [UserEditorSettingsUpsertArgsSnippetsItem]?
    let extensions: String?
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = settingsJson { result["settingsJson"] = value }
        if let value = keybindingsJson { result["keybindingsJson"] = value }
        if let value = snippets { result["snippets"] = convexEncodeArray(value) }
        if let value = extensions { result["extensions"] = value }
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct UserEditorSettingsClearArgs {
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct UsersGetCurrentBasicArgs {
    // Unsupported args shape
}

struct WorkspaceConfigsGetArgs {
    let projectFullName: String
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["projectFullName"] = projectFullName
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct WorkspaceConfigsUpsertArgs {
    let maintenanceScript: String?
    let dataVaultKey: String?
    let projectFullName: String
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = maintenanceScript { result["maintenanceScript"] = value }
        if let value = dataVaultKey { result["dataVaultKey"] = value }
        result["projectFullName"] = projectFullName
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct WorkspaceSettingsGetArgs {
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

struct WorkspaceSettingsUpdateArgs {
    let worktreePath: String?
    let autoPrEnabled: Bool?
    let autoSyncEnabled: Bool?
    let heatmapModel: String?
    let heatmapThreshold: Double?
    let heatmapTooltipLanguage: String?
    let heatmapColors: WorkspaceSettingsUpdateArgsHeatmapColors?
    let conversationTitleStyle: WorkspaceSettingsUpdateArgsConversationTitleStyleEnum?
    let conversationTitleCustomPrompt: String?
    let acpSandboxProvider: WorkspaceSettingsUpdateArgsAcpSandboxProviderEnum?
    let mcpServers: [WorkspaceSettingsUpdateArgsMcpServersItem]?
    let teamSlugOrId: String

    func asDictionary() -> [String: ConvexEncodable?] {
        var result: [String: ConvexEncodable?] = [:]
        if let value = worktreePath { result["worktreePath"] = value }
        if let value = autoPrEnabled { result["autoPrEnabled"] = value }
        if let value = autoSyncEnabled { result["autoSyncEnabled"] = value }
        if let value = heatmapModel { result["heatmapModel"] = value }
        if let value = heatmapThreshold { result["heatmapThreshold"] = value }
        if let value = heatmapTooltipLanguage { result["heatmapTooltipLanguage"] = value }
        if let value = heatmapColors { result["heatmapColors"] = value }
        if let value = conversationTitleStyle { result["conversationTitleStyle"] = value }
        if let value = conversationTitleCustomPrompt { result["conversationTitleCustomPrompt"] = value }
        if let value = acpSandboxProvider { result["acpSandboxProvider"] = value }
        if let value = mcpServers { result["mcpServers"] = convexEncodeArray(value) }
        result["teamSlugOrId"] = teamSlugOrId
        return result
    }
}

typealias AcpSubscribeNewMessagesReturn = [AcpSubscribeNewMessagesItem]

typealias AcpGetMessagesReturn = [AcpGetMessagesItem]

typealias AcpSandboxesListForTeamReturn = [AcpSandboxesListForTeamItem]

typealias ApiKeysGetAllReturn = [ApiKeysGetAllItem]

typealias ApiKeysRemoveReturn = String

typealias ApiKeysGetAllForAgentsReturn = [String: String]

typealias CodeReviewListFileOutputsForPrReturn = [CodeReviewListFileOutputsForPrItem]

typealias CodeReviewListFileOutputsForComparisonReturn = [CodeReviewListFileOutputsForComparisonItem]

typealias CodexTokensRemoveReturn = String

typealias CommentsListCommentsReturn = [CommentsListCommentsItem]

typealias CommentsResolveCommentReturn = String

typealias CommentsArchiveCommentReturn = String

typealias CommentsGetRepliesReturn = [CommentsGetRepliesItem]

typealias ContainerSettingsUpdateReturn = String

typealias ConversationsListByNamespaceReturn = [ConversationsListByNamespaceItem]

typealias ConversationsListBySandboxReturn = [ConversationsListBySandboxItem]

typealias CrownGetTasksWithCrownsReturn = [ConvexId<ConvexTableTasks>]

typealias DevboxInstancesListReturn = [DevboxInstancesListItem]

typealias DevboxInstancesUpdateStatusReturn = String

typealias DevboxInstancesRecordAccessReturn = String

typealias DevboxInstancesRemoveReturn = String

typealias E2bInstancesRecordResumeReturn = String

typealias EnvironmentSnapshotsListReturn = [EnvironmentSnapshotsListItem]

typealias EnvironmentSnapshotsRemoveReturn = String

typealias EnvironmentsListReturn = [EnvironmentsListItem]

typealias EnvironmentsUpdateExposedPortsReturn = [Double]

typealias EnvironmentsRemoveReturn = String

typealias GithubGetReposByOrgReturn = [String: [GithubGetReposByOrgReturnValueItem]]

typealias GithubGetBranchesReturn = [String]

typealias GithubGetAllReposReturn = [GithubGetAllReposItem]

typealias GithubGetReposByInstallationReturn = [GithubGetReposByInstallationItem]

typealias GithubGetBranchesByRepoReturn = [GithubGetBranchesByRepoItem]

typealias GithubHasReposForTeamReturn = Bool

typealias GithubListProviderConnectionsReturn = [GithubListProviderConnectionsItem]

typealias GithubListUnassignedProviderConnectionsReturn = [GithubListUnassignedProviderConnectionsItem]

typealias GithubUpsertRepoReturn = ConvexId<ConvexTableRepos>?

typealias GithubBulkInsertReposReturn = [GithubBulkInsertReposItem]

typealias GithubBulkInsertBranchesReturn = [GithubBulkInsertBranchesItem]

typealias GithubBulkUpsertBranchesWithActivityReturn = [GithubBulkUpsertBranchesWithActivityItem]

typealias GithubReplaceAllReposReturn = [GithubReplaceAllReposItem]

typealias GithubCheckRunsGetCheckRunsForPrReturn = [GithubCheckRunsGetCheckRunsForPrItem]

typealias GithubCommitStatusesGetCommitStatusesForPrReturn = [GithubCommitStatusesGetCommitStatusesForPrItem]

typealias GithubDeploymentsGetDeploymentsForPrReturn = [GithubDeploymentsGetDeploymentsForPrItem]

typealias GithubPrsListPullRequestsReturn = [GithubPrsListPullRequestsItem]

typealias GithubWorkflowsGetWorkflowRunsReturn = [GithubWorkflowsGetWorkflowRunsItem]

typealias GithubWorkflowsGetWorkflowRunsForPrReturn = [GithubWorkflowsGetWorkflowRunsForPrItem]

typealias HostScreenshotCollectorListReleasesReturn = [HostScreenshotCollectorListReleasesItem]

typealias MorphInstancesRecordResumeReturn = String

typealias PreviewConfigsListByTeamReturn = [PreviewConfigsListByTeamItem]

typealias PreviewRunsListByConfigReturn = [PreviewRunsListByConfigItem]

typealias PreviewRunsListByTeamReturn = [PreviewRunsListByTeamItem]

typealias PreviewTestJobsListTestRunsReturn = [PreviewTestJobsListTestRunsItem]

typealias PushTokensUpsertReturn = String

typealias PushTokensRemoveReturn = String

typealias PushTokensSendTestReturn = String

typealias StackUpsertUserPublicReturn = String

typealias StackDeleteUserPublicReturn = String

typealias StackUpsertTeamPublicReturn = String

typealias StackDeleteTeamPublicReturn = String

typealias StackEnsureMembershipPublicReturn = String

typealias StackDeleteMembershipPublicReturn = String

typealias StackEnsurePermissionPublicReturn = String

typealias StackDeletePermissionPublicReturn = String

typealias StorageGenerateUploadUrlReturn = String

typealias StorageGetUrlReturn = String

typealias StorageGetUrlsReturn = [StorageGetUrlsItem]

typealias TaskCommentsListByTaskReturn = [TaskCommentsListByTaskItem]

typealias TaskNotificationsListReturn = [TaskNotificationsListItem]

typealias TaskNotificationsHasUnreadForTaskReturn = Bool

typealias TaskNotificationsGetUnreadCountReturn = Double

typealias TaskNotificationsGetTasksWithUnreadReturn = [TaskNotificationsGetTasksWithUnreadItem]

typealias TaskNotificationsMarkTaskRunAsReadReturn = String

typealias TaskNotificationsMarkTaskRunAsUnreadReturn = String

typealias TaskNotificationsMarkTaskAsReadReturn = String

typealias TaskNotificationsMarkTaskAsUnreadReturn = String

typealias TaskNotificationsMarkAllAsReadReturn = String

typealias TaskRunLogChunksAppendChunkReturn = String

typealias TaskRunLogChunksAppendChunkPublicReturn = String

typealias TaskRunLogChunksGetChunksReturn = [TaskRunLogChunksGetChunksItem]

typealias TaskRunsGetByTaskReturn = [TaskRunsGetByTaskItem]

typealias TaskRunsUpdateSummaryReturn = String

typealias TaskRunsUpdateWorktreePathReturn = String

typealias TaskRunsUpdateBranchReturn = String

typealias TaskRunsUpdateBranchBatchReturn = String

typealias TaskRunsUpdateStatusPublicReturn = String

typealias TaskRunsUpdateVSCodeInstanceReturn = String

typealias TaskRunsUpdateVSCodeStatusReturn = String

typealias TaskRunsUpdateVSCodePortsReturn = String

typealias TaskRunsUpdateVSCodeStatusMessageReturn = String

typealias TaskRunsCompleteReturn = String

typealias TaskRunsFailReturn = String

typealias TaskRunsAddCustomPreviewReturn = Double

typealias TaskRunsRemoveCustomPreviewReturn = String

typealias TaskRunsUpdateCustomPreviewUrlReturn = String

typealias TaskRunsGetActiveVSCodeInstancesReturn = [TaskRunsGetActiveVSCodeInstancesItem]

typealias TaskRunsUpdateLastAccessedReturn = String

typealias TaskRunsToggleKeepAliveReturn = String

typealias TaskRunsUpdatePullRequestUrlReturn = String

typealias TaskRunsUpdatePullRequestStateReturn = String

typealias TaskRunsUpdateNetworkingReturn = String

typealias TaskRunsUpdateEnvironmentErrorReturn = String

typealias TaskRunsArchiveReturn = String

typealias TaskRunsGetContainersToStopReturn = [TaskRunsGetContainersToStopItem]

typealias TasksGetReturn = [TasksGetItem]

typealias TasksGetWithNotificationOrderReturn = [TasksGetWithNotificationOrderItem]

typealias TasksGetPreviewTasksReturn = [TasksGetPreviewTasksItem]

typealias TasksGetPinnedReturn = [TasksGetPinnedItem]

typealias TasksGetTasksWithTaskRunsReturn = [TasksGetTasksWithTaskRunsItem]

typealias TasksRemoveReturn = String

typealias TasksToggleReturn = String

typealias TasksSetCompletedReturn = String

typealias TasksUpdateReturn = String

typealias TasksUpdateWorktreePathReturn = String

typealias TasksGetVersionsReturn = [TasksGetVersionsItem]

typealias TasksArchiveReturn = String

typealias TasksUnarchiveReturn = String

typealias TasksPinReturn = String

typealias TasksUnpinReturn = String

typealias TasksUpdateCrownErrorReturn = String

typealias TasksTryBeginCrownEvaluationReturn = Bool

typealias TasksSetPullRequestDescriptionReturn = String

typealias TasksSetPullRequestTitleReturn = String

typealias TasksGetTasksWithPendingCrownEvaluationReturn = [TasksGetTasksWithPendingCrownEvaluationItem]

typealias TasksUpdateMergeStatusReturn = String

typealias TeamsListTeamMembershipsReturn = [TeamsListTeamMembershipsItem]

typealias UserEditorSettingsClearReturn = String

typealias WorkspaceSettingsUpdateReturn = String
