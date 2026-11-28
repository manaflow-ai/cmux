// Wire types of the brain host's inspector API (Native/OptChat/optchat-chief/src/inspect).

export type Usage = { input: number; cache_read: number; cache_write: number; output: number };

export type TurnRow = {
  turn: string;
  first: number;
  ts: number;
  engine?: string;
  harness?: string;
  model?: string | null;
  effort?: string | null;
  settle_ms?: number | null;
  view_bytes?: number;
  view_lines?: number;
  unchanged_prefix_bytes?: number | null;
  parts_recorded?: boolean;
  messages?: number;
  nodes_before?: number;
  nodes_before_ms?: number;
  nodes_during?: number;
  tool_names?: Record<string, number>;
  status: string | null;
  ms?: number | null;
  first_usage?: Usage | null;
  usage?: Usage | null;
  cost_usd?: number | null;
  requests?: number;
  tools?: number;
  tool_errors?: number;
  error?: string | null;
  hit_rate?: number | null;
};

export type Status = {
  messages: number;
  view_lines: number;
  view_bytes: number;
  budget: number;
  unbuilt: number;
  nodes_built: number;
  busy: string[];
  failures: { node: string; error: string }[];
  fatal: string | null;
  closed: boolean;
  settled: boolean;
  settle: { built: number; total: number } | null;
  top_level: number | null;
  running_turn: TurnRow | null;
  last_turn: TurnRow | null;
  last_error: { ts: number; ev: string; error: string | null; node?: string; turn?: string } | null;
  trace_on: boolean;
  constants: { node_bytes: number; view_bytes: number; marks: number[]; grid: number; placeholder: string };
};

export type ViewLine = {
  name: string;
  level: number;
  start: number;
  n: number;
  offset: number;
  bytes: number;
  built: boolean;
  text: string;
};

export type SystemPart = { label: string; explain: string; text: string; bytes: number };

export type Block = {
  role: "system" | "user";
  kind: "instructions" | "view" | "messages";
  bytes: number;
  view_start?: number;
  cache: "harness" | "ours" | "none";
};

export type TurnPrompt = {
  turn: string;
  ts?: number;
  harness?: string;
  model?: string | null;
  layout: "cached" | "blocks";
  exact: { view: boolean; system: boolean; messages: boolean };
  note: string | null;
  view: {
    text: string;
    bytes: number;
    marks: number[];
    grid: number[];
    unchanged_prefix_bytes?: number | null;
    parts: string[];
  } | null;
  messages: { id: number; kind: string; text: string }[];
  system?: { bytes: number };
  lines?: ViewLine[];
  system_parts: SystemPart[];
  blocks?: Block[];
  events?: Record<string, unknown>[];
};

export type NodeBrief = {
  name: string;
  level: number;
  start: number;
  n: number;
  built: boolean;
  bytes: number | null;
  text: string | null;
};

export type NodeDetail = NodeBrief & {
  end: number;
  date_first: string | null;
  date_last: string | null;
  parent: string | null;
  in_view: boolean;
  zoom: { call: string; answer: string };
  children?: [NodeBrief, NodeBrief];
  message?: { id: number; kind: string; text: string; bytes: number } | null;
};

export type Level = { level: number; per_node: number; count: number; from: number; nodes: NodeBrief[] };

export type SearchHit =
  | { type: "message"; id: number; kind: string; snippet: string; name: string }
  | { type: "node"; name: string; level: number; snippet: string };
