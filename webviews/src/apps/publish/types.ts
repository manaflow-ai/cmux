// The Apps tier's Rust answers (cmux-tui/crates/cmux-apps/src/ui.rs, serde camelCase), as drawn.
export type Audience = "private" | "team";

export type PublishPopover = {
  name: string;
  slug: string | null;
  hostLabel: string | null;
  audience: Audience;
  startFrom: string;
  machine: string;
  machineName: string;
  port: number;
  argv: string[];
  command: string;
  canPublish: boolean;
  problem: "nameEmpty" | null;
};

export type PublishOutcome =
  | { kind: "published"; slug: string; version: number | null; url: string | null; warnings: string[] }
  | { kind: "failed"; code: string; message: string; version: number | null };

export type AppsRow = {
  slug: string;
  title: string;
  detail: string;
  dot: "live" | "off";
  pinned: boolean;
  url: string | null;
};

export type AppsSection = { rows: AppsRow[]; publishRow: boolean; error: string | null };
