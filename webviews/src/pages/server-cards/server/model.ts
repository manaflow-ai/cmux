// What the server surfaces derive from the app's status: the code field's shape, the health order,
// the overall line, the panel's facts, and the Add Server card's buttons and keys. Pure, so the
// tests pin each rule; the views only draw them.
import type {
  AddServerStepName,
  HealthAlert,
  HealthSeverity,
  ServerApprover,
  ServerSnapshot,
  ServerStatus,
} from "./types";

// MARK: - Pairing code

const ALPHABET = new Set("0123456789ABCDEFGHJKMNPQRSTVWXYZ");
const SEPARATORS = new Set(["-", " ", "‐", "‑", "–", "—"]);

/** Pairing code rules (the app's PairingCode): 8 Crockford base32 symbols, shown `XXXX-XXXX`, case
 * insensitive, `O` reads as `0` and `I`/`L` as `1`. */
export const PairingCode = {
  /** `7KQ4M2XD` → `7KQ4-M2XD`; other lengths unchanged. */
  display(code: string): string {
    return code.length === 8 ? `${code.slice(0, 4)}-${code.slice(4)}` : code;
  },

  /** Canonical symbols of what a person typed; symbols outside the alphabet stay. */
  normalize(input: string): string {
    let out = "";
    for (const character of input.toUpperCase()) {
      if (SEPARATORS.has(character)) continue;
      out += character === "O" ? "0" : character === "I" || character === "L" ? "1" : character;
    }
    return out;
  },

  isComplete(input: string): boolean {
    const code = PairingCode.normalize(input);
    return code.length === 8 && Array.from(code).every((symbol) => ALPHABET.has(symbol));
  },

  /** What the code field shows while typing: normalized, at most 8 symbols, a dash after the fourth. */
  editing(input: string): string {
    const code = Array.from(PairingCode.normalize(input))
      .filter((symbol) => ALPHABET.has(symbol))
      .slice(0, 8)
      .join("");
    return code.length > 4 ? `${code.slice(0, 4)}-${code.slice(4)}` : code;
  },
};

// MARK: - Health order

const RANK: Record<HealthSeverity, number> = { info: 0, warning: 1, critical: 2 };

export function isOpen(alert: HealthAlert): boolean {
  return alert.resolvedAt === undefined;
}

function byCheck(a: HealthAlert, b: HealthAlert): number {
  return a.check < b.check ? -1 : a.check > b.check ? 1 : 0;
}

function urgency(a: HealthAlert, b: HealthAlert): number {
  if (a.severity !== b.severity) return RANK[b.severity] - RANK[a.severity];
  if (a.raisedAt !== b.raisedAt) return b.raisedAt - a.raisedAt;
  return byCheck(a, b);
}

export interface ChecklistRow {
  check: string;
  /** The open alert; absent when the check passes. */
  alert?: HealthAlert;
}

export const HealthOrdering = {
  /** Open alerts: critical, warning, info; newest first within a severity; check id breaks ties. */
  open(alerts: readonly HealthAlert[]): HealthAlert[] {
    return alerts.filter(isOpen).sort(urgency);
  },

  /** One row per check: checks with an open alert first (urgency order), then the passing checks in
   * their reported order. Resolved alerts never show here. */
  checklist(checks: readonly string[], alerts: readonly HealthAlert[]): ChecklistRow[] {
    const seen = new Set<string>();
    const rows: ChecklistRow[] = [];
    for (const alert of HealthOrdering.open(alerts)) {
      if (seen.has(alert.check)) continue;
      seen.add(alert.check);
      rows.push({ check: alert.check, alert });
    }
    for (const check of checks) {
      if (seen.has(check)) continue;
      seen.add(check);
      rows.push({ check });
    }
    return rows;
  },

  /** Every alert, newest event first (a resolve counts at its resolve time). */
  timeline(alerts: readonly HealthAlert[]): HealthAlert[] {
    return [...alerts].sort((a, b) => {
      const ta = a.resolvedAt ?? a.raisedAt;
      const tb = b.resolvedAt ?? b.raisedAt;
      return ta !== tb ? tb - ta : byCheck(a, b);
    });
  },

  /** The most urgent open severity; undefined when every check passes. */
  worst(alerts: readonly HealthAlert[]): HealthSeverity | undefined {
    let worst: HealthSeverity | undefined;
    for (const alert of alerts) {
      if (isOpen(alert) && (worst === undefined || RANK[alert.severity] > RANK[worst])) worst = alert.severity;
    }
    return worst;
  },
};

// MARK: - Overall and the panel's facts

export type ServerOverall =
  | { kind: "unavailable" }
  | { kind: "off" }
  | { kind: "unpaired" }
  | { kind: "pairing" }
  | { kind: "serving" }
  | { kind: "attention"; severity: HealthSeverity };

/** The overall line, most important state first. */
export function overallOf(status: Pick<ServerStatus, "connection" | "snapshot">): ServerOverall {
  const { connection, snapshot } = status;
  if (connection.state !== "connected" || !snapshot) return { kind: "unavailable" };
  if (!snapshot.enabled) return { kind: "off" };
  if (snapshot.pairing.state === "unpaired") return { kind: "unpaired" };
  if (snapshot.pairing.state === "pairing") return { kind: "pairing" };
  const worst = HealthOrdering.worst(snapshot.alerts);
  if (worst !== undefined && worst !== "info") return { kind: "attention", severity: worst };
  return { kind: "serving" };
}

export function roleState(snapshot: ServerSnapshot, role: string) {
  return snapshot.roles.find((entry) => entry.role === role)?.state ?? "off";
}

/** Used share of a database's quota, 0...1 (0 without a quota). */
export function usage(database: { sizeBytes: number; quotaBytes: number }): number {
  return database.quotaBytes > 0 ? Math.min(Math.max(database.sizeBytes / database.quotaBytes, 0), 1) : 0;
}

/** Values the panel layouts share. */
export function panelFacts(snapshot: ServerSnapshot) {
  const hosted = snapshot.appServers.filter((app) => app.holdsLease);
  const running = hosted.filter((app) => app.state === "running").length;
  const issues = HealthOrdering.open(snapshot.alerts).filter((alert) => alert.severity !== "info");
  return {
    appsValue: hosted.length === 0 ? "–" : `${running}/${hosted.length}`,
    appsTroubled: hosted.some((app) => app.state === "crashloop"),
    databaseBytes: snapshot.databases.reduce((sum, database) => sum + database.sizeBytes, 0),
    hasDatabases: snapshot.databases.length > 0,
    /** Open warnings and criticals (info alerts do not count against health). */
    issues,
    worstIssue: HealthOrdering.worst(issues),
  };
}

// MARK: - Add Server

export type AddServerAction = "approve" | "retry" | "done" | "cancel";

/** One footer button: what it does, whether Return (`isDefault`) or Escape presses it, and whether it is on. */
export interface AddServerButton {
  action: AddServerAction;
  isDefault: boolean;
  enabled: boolean;
}

/** The footer: an Escape button and a Return button, or only Done once the server was added. */
export function addServerButtons(approver: Pick<ServerApprover, "step" | "canApprove">): AddServerButton[] {
  if (approver.step === "added") return [{ action: "done", isDefault: true, enabled: true }];
  const cancel: AddServerButton = { action: "cancel", isDefault: false, enabled: true };
  const action = approver.step === "approveFailed" ? "retry" : "approve";
  return [cancel, { action, isDefault: true, enabled: approver.canApprove }];
}

/** Whether only the person's own click on the button answers it: Approve and Try Again add a
 * server to the person's team, so they are the card panel's native footer (WebCardPanel's
 * PersonControl), never the page's. */
export function isClickOnly(action: AddServerAction): boolean {
  return action === "approve" || action === "retry";
}

/** The button a key presses (Return the default one, Escape the other), when it is on and a key
 * may press it: Return never approves. */
export function buttonForKey(buttons: readonly AddServerButton[], key: string): AddServerButton | undefined {
  if (key !== "Enter" && key !== "Escape") return undefined;
  const button = buttons.find((entry) => entry.isDefault === (key === "Enter"));
  return button?.enabled && !isClickOnly(button.action) ? button : undefined;
}

/** The Escape button's title key: Deny once a server is on the card, else Cancel. */
export function escapeTitleKey(step: AddServerStepName): string {
  return step === "review" || step === "approving" || step === "approveFailed" ? "approver.deny" : "approver.cancel";
}

/** The Return button's title key. */
export function returnTitleKey(step: AddServerStepName): string {
  switch (step) {
    case "approving":
      return "approver.adding";
    case "approveFailed":
      return "approver.retry";
    case "added":
      return "approver.done";
    default:
      return "approver.approve";
  }
}

/** A server is on the card: its facts, words and options show. */
export function showsCandidate(step: AddServerStepName): boolean {
  return step === "review" || step === "approving" || step === "approveFailed";
}

/** Which layout shows: the card changes size between layouts, never on a keystroke. */
export function layoutOf(step: AddServerStepName): "code" | "review" | "failed" | "added" {
  switch (step) {
    case "review":
    case "approving":
      return "review";
    case "approveFailed":
      return "failed";
    case "added":
      return "added";
    default:
      return "code";
  }
}
