export type FeedQuestionOption = {
  description?: string;
  id: string;
  label: string;
};

export type FeedQuestion = {
  header?: string;
  id: string;
  multi_select: boolean;
  options: FeedQuestionOption[];
  prompt: string;
};

export type FeedItem = {
  allowed_permission_modes?: Array<"all" | "always" | "bypass" | "deny" | "once">;
  created_at: string;
  cwd?: string;
  default_mode?: string;
  id: string;
  kind: string;
  plan?: string;
  question_options?: FeedQuestionOption[];
  question_prompt?: string;
  questions?: FeedQuestion[];
  request_id?: string;
  source: string;
  status: "expired" | "pending" | "resolved" | "telemetry";
  text?: string;
  title?: string;
  tool_input?: string;
  tool_name?: string;
  tool_result?: string;
  workstream_id: string;
};

export type FeedCopy = {
  actionable: string;
  activity: string;
  allowAlways: string;
  allowAll: string;
  allowBypass: string;
  allowOnce: string;
  deny: string;
  emptyActionable: string;
  emptyActivity: string;
  feed: string;
  loadOlder: string;
  loadingOlder: string;
  planAuto: string;
  planManual: string;
  planUltraplan: string;
  questionSubmit: string;
  questionPlaceholder: string;
  requestFailed: string;
};

export type FeedSnapshot = {
  copy: FeedCopy;
  hasMore: boolean;
  isLoadingOlder: boolean;
  items: FeedItem[];
  sourceIcons: Record<string, string>;
  theme: {
    background: string;
    foreground: string;
    isLight: boolean;
  };
};

export type FeedNativeEvent = {
  snapshot: FeedSnapshot;
  type: "feed.snapshot";
};
