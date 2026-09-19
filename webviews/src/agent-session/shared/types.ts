export type ProviderId = "codex" | "claude" | "opencode";

export type RendererKind = "react" | "solid" | "guiMode";

export type ComposerPermissionMode = "default" | "auto-review" | "full-access" | "custom";

export type ProviderInfo = {
  id: ProviderId;
  displayName: string;
  executableName: string;
  transportKind: "stdio-jsonrpc" | "stdio-jsonl" | "http-loopback";
  arguments: string[];
  autoStart: boolean;
};

export type AgentSessionTheme = {
  isDark: boolean;
  pageBackground: string;
  surfaceBackground: string;
  surfaceElevatedBackground: string;
  inputBackground: string;
  border: string;
  borderStrong: string;
  text: string;
  mutedText: string;
  softText: string;
  accent: string;
  accentSoft: string;
  danger: string;
  shadow: string;
};

export type AppContext = {
  panelId: string;
  workspaceId: string;
  renderer: RendererKind;
  initialProviderId: ProviderId;
  workingDirectory?: string;
  rateLimitRows?: AgentSessionRateLimitRow[];
  copy: AgentSessionCopy;
  theme: AgentSessionTheme;
  guiMode?: GuiModeSessionContext;
};

export type GuiModeSessionContext = {
  copy?: {
    chatMode?: string;
    emptySubtitle?: string;
    emptyTitle?: string;
    folderFallback?: string;
    localLabel?: string;
    modelLabel?: string;
    modeLabel?: string;
    noProvidersFound?: string;
    providerLabel?: string;
    providerSearchPlaceholder?: string;
    reasoningLabel?: string;
    reasoningDefault?: string;
    reasoningLow?: string;
    reasoningMedium?: string;
    reasoningHigh?: string;
    reasoningExtraHigh?: string;
    taskPromptLabel?: string;
    taskTitle?: string;
    terminalMode?: string;
    terminalPlaceholder?: string;
    terminalErrorMessage?: string;
    voiceAction?: string;
    voiceDescription?: string;
    voiceTitle?: string;
  };
  gitBranch?: string;
  providers?: Array<{
    accentColor?: string;
    displayName: string;
    id: ProviderId;
  }>;
  models?: Array<{
    displayName: string;
    id: string;
    providerId: string;
    reasoningEfforts: string[];
    defaultReasoningEffort?: string;
    isDefault?: boolean;
  }>;
  page?: "home" | "task-worktree-pr";
  prompt?: string;
  selectedModelId?: string;
  selectedReasoningEffort?: string;
  workingDirectory?: string;
};

export type AgentSessionRateLimitRow = {
  role: "primary" | "secondary";
  remainingPercent: number;
  usedPercent?: number;
  windowDurationMins?: number;
  resetsAt?: number;
};

export type AgentSessionCopy = {
  start: string;
  stop: string;
  send: string;
  provider: string;
  rateLimits: string;
  rateLimitUsageRemaining: string;
  rateLimitPrimary: string;
  rateLimitSecondary: string;
  rateLimitWeekly: string;
  rateLimitMonthly: string;
  rateLimitDaysFormat: string;
  rateLimitHoursFormat: string;
  rateLimitMinutesFormat: string;
  rateLimitResets: string;
  voiceInput: string;
  promptPlaceholder: string;
  attachFile: string;
  addFilesAndMore: string;
  addPhotosAndFiles: string;
  removeAttachment: string;
  copyOutput: string;
  copyAssistantMessage: string;
  copiedAssistantMessage: string;
  copyUserMessage: string;
  copiedUserMessage: string;
  shellLabel: string;
  copyShellContents: string;
  copiedShellContents: string;
  collapseShell: string;
  shellSuccess: string;
  showMore: string;
  showLess: string;
  browseWeb: string;
  autoContext: string;
  includeIdeContext: string;
  ideContext: string;
  tools: string;
  changePermissions: string;
  permissionsDefault: string;
  permissionsFullAccess: string;
  permissionsAutoReview: string;
  permissionsCustom: string;
  reasoningEffortHigh: string;
  mentionMenuTitle: string;
  mentionCurrentWorkspace: string;
  skillMenuTitle: string;
  composerNoResults: string;
  planMode: string;
  planSuggestionAction: string;
  planSuggestionDismiss: string;
  planSuggestionShortcut: string;
  planSuggestionTitle: string;
  skillPlan: string;
  skillCodeReview: string;
  skillResearch: string;
  loadingStatus: string;
  idleStatus: string;
  startingStatus: string;
  runningStatus: string;
  stoppingStatus: string;
  failedStatus: string;
  rendererReadyFormat: string;
  stopped: string;
  sentCharsFormat: string;
  providerStarted: string;
  providerExitedFormat: string;
  requestFailed: string;
};

export type AgentSessionAttachment = {
  dataUrl?: string;
  fsPath?: string;
  id: string;
  kind: "file" | "image";
  label: string;
  mimeType?: string;
  path: string;
};

export type AgentEvent =
  | {
      type: "app.workingDirectory";
      workingDirectory: string;
      gitBranch?: string;
    }
  | {
      type: "provider.models";
      sessionId: string;
      providerId: ProviderId;
      models: NonNullable<GuiModeSessionContext["models"]>;
    }
  | {
      type: "app.theme";
      theme: AgentSessionTheme;
    }
  | {
      type: "app.rateLimitRows";
      rateLimitRows: AgentSessionRateLimitRow[];
    }
  | {
      type: "provider.started";
      sessionId: string;
      providerId: ProviderId;
      executablePath: string;
      arguments: string[];
    }
  | {
      type: "provider.output";
      sessionId: string;
      providerId: ProviderId;
      stream: "stdout" | "stderr" | "error";
      text: string;
    }
  | {
      type: "provider.activity";
      sessionId: string;
      providerId: ProviderId;
      activityId: string;
      kind: "command" | "fileChange" | "other";
      status: "inProgress" | "completed" | "failed" | "stopped";
      action: string;
      detail?: string;
      outputDelta?: string;
    }
  | {
      type: "provider.turnComplete";
      sessionId: string;
      providerId: ProviderId;
    }
  | {
      type: "provider.exit";
      sessionId: string;
      providerId: ProviderId;
      status: number;
    };
