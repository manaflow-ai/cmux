export type IssueProvider = "github" | "linear";
export type IssueStatus = "open" | "closed";
export type IssueSpawnAgent = "claude" | "codex" | "none";

export type IssueInboxTheme = {
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

export type IssueInboxItem = {
  id: string;
  provider: IssueProvider;
  source_url: string;
  title: string;
  status: IssueStatus;
  provider_state: string | null;
  updated_at: string;
  repo_or_project: string;
  number: string;
  assignees: string[];
  labels: string[];
};

export type IssueInboxSource = {
  id: string;
  display_name: string;
  provider: IssueProvider;
  project_root: string | null;
  spawn?: {
    dev_server_command: string | null;
    web_url: string | null;
    default_agent: IssueSpawnAgent | null;
  };
};

export type IssueInboxConfigSnapshot = {
  path: string;
  file_exists: boolean;
  warnings: Array<{ id: string; message: string }>;
  sources: IssueInboxSource[];
};

export type IssueInboxSnapshot = {
  items: IssueInboxItem[];
  source_errors: Record<string, string>;
  fetched_at: Record<string, string>;
  refreshing: string[];
  config: IssueInboxConfigSnapshot;
  labels?: Record<string, string>;
  theme?: IssueInboxTheme;
};

export type IssueInboxStoreState = {
  snapshot: IssueInboxSnapshot | null;
  loading: boolean;
  refreshing: boolean;
  error: string | null;
};
