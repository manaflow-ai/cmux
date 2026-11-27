// l10n-allow-file: gallery fixture text, not shipped UI.
// Generated from the Rust rules (cmux-tui/crates/cmux-apps/src/ui.rs, ops apps_tier_*): each value is
// what `cmux_apps::ui::respond` answered for a sample page, draft, publish run or account list.
import type { AppsSection, PublishOutcome, PublishPopover } from "./types";

export const popoverPrivate: PublishPopover = {
  argv: ["cmux", "app", "publish", "invoice-triage", "--port", "3000", "--json"],
  audience: "private",
  canPublish: true,
  command: "cmux app publish invoice-triage --port 3000 --json",
  hostLabel: "a-invoice-triage--…",
  machine: "cm_k7x2m9qa",
  machineName: "atlas-dev",
  name: "Invoice triage",
  port: 3000,
  problem: null,
  slug: "invoice-triage",
  startFrom: "Inferred from port 3000 on atlas-dev",
};

export const popoverTeam: PublishPopover = {
  argv: ["cmux", "app", "publish", "q3-board", "--port", "3000", "--share", "team", "--json"],
  audience: "team",
  canPublish: true,
  command: "cmux app publish q3-board --port 3000 --share team --json",
  hostLabel: "a-q3-board--…",
  machine: "cm_k7x2m9qa",
  machineName: "atlas-dev",
  name: "Q3 board",
  port: 3000,
  problem: null,
  slug: "q3-board",
  startFrom: "Inferred from port 3000 on atlas-dev",
};

export const popoverNameEmpty: PublishPopover = {
  argv: [],
  audience: "private",
  canPublish: false,
  command: "",
  hostLabel: null,
  machine: "cm_k7x2m9qa",
  machineName: "atlas-dev",
  name: "!!!",
  port: 3000,
  problem: "nameEmpty",
  slug: null,
  startFrom: "Inferred from port 3000 on atlas-dev",
};

export const published: PublishOutcome = {
  kind: "published",
  slug: "invoice-triage",
  url: "https://a-invoice-triage--abcdefgh.preview.cmux.dev",
  version: 3,
  warnings: [],
};

export const failed: PublishOutcome = {
  code: "probe_failed",
  kind: "failed",
  message: "GET / on port 3000 answered 502 for 30 s; v3 failed, v2 stays live",
  version: 3,
};

export const section: AppsSection = {
  error: null,
  publishRow: true,
  rows: [
    {
      detail: "v3",
      dot: "live",
      pinned: true,
      slug: "invoice-triage",
      title: "Invoice triage",
      url: "https://a-invoice-triage--abcdefgh.preview.cmux.dev",
    },
    {
      detail: "v7",
      dot: "live",
      pinned: false,
      slug: "pricing-calculator",
      title: "Pricing calculator",
      url: "https://a-pricing-calculator--abcdefgh.preview.cmux.dev",
    },
    {
      detail: "v2",
      dot: "live",
      pinned: false,
      slug: "q3-board",
      title: "Q3 board",
      url: "https://a-q3-board--abcdefgh.preview.cmux.dev",
    },
    {
      detail: "not live",
      dot: "off",
      pinned: false,
      slug: "support-inbox",
      title: "Support inbox",
      url: null,
    },
  ],
};

export const sectionError: AppsSection = {
  error: "cmux Cloud did not answer",
  publishRow: true,
  rows: [],
};

export const sectionEmpty: AppsSection = {
  error: null,
  publishRow: true,
  rows: [],
};
