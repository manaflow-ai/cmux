export type ProviderId = "codex" | "claude" | "opencode";

export type RendererKind = "react" | "solid";

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
      stream: "stdout" | "stderr";
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
