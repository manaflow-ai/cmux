// In-memory stand-in for the PlanetScale database. It implements exactly the
// statements the Worker issues (keyed by SQL text) and throws on anything else,
// so a changed query fails loudly instead of silently returning nothing.
import type { Db } from "../src/db";

type Row = Record<string, unknown>;
type V = unknown[];

const mysql = (d: Date) => d.toISOString().replace("T", " ").replace("Z", "");
const t = (v: unknown) => (v instanceof Date ? v.getTime() : new Date(`${String(v).replace(" ", "T")}Z`).getTime());

function out(r: Row): Row {
  const o: Row = {};
  for (const [k, v] of Object.entries(r)) o[k] = v instanceof Date ? mysql(v) : v;
  return o;
}

export class FakeDb implements Db {
  users: Row[] = [];
  identities: Row[] = [];
  emailCodes: Row[] = [];
  refreshTokens: Row[] = [];
  hosts: Row[] = [];
  pairings: Row[] = [];
  rateEvents: Row[] = [];
  calls: string[] = [];
  private seq = 0;

  private handlers: Record<string, (v: V) => Row[] | number> = {
    // users
    "SELECT * FROM users WHERE id = ?": (v) => this.users.filter((u) => u.id === v[0]),
    "SELECT id FROM users WHERE id = ?": (v) => this.users.filter((u) => u.id === v[0]).map((u) => ({ id: u.id })),
    "SELECT * FROM users WHERE email = ?": (v) => this.users.filter((u) => u.email === v[0]),
    "INSERT INTO users (id, email, display_name, created_at, updated_at) VALUES (?, ?, ?, ?, ?)": (v) =>
      this.users.push({ id: v[0], email: v[1], display_name: v[2], created_at: v[3], updated_at: v[4] }) && 1,
    "UPDATE users SET display_name = ?, updated_at = ? WHERE id = ?": (v) =>
      this.update(this.users, (u) => u.id === v[2], { display_name: v[0], updated_at: v[1] }),
    "DELETE FROM users WHERE id = ?": (v) => this.del("users", (u) => u.id === v[0]),
    // identities
    "SELECT user_id FROM auth_identities WHERE provider = ? AND subject = ?": (v) =>
      this.identities.filter((i) => i.provider === v[0] && i.subject === v[1]),
    "INSERT IGNORE INTO auth_identities (id, user_id, provider, subject, email, created_at) VALUES (?, ?, ?, ?, ?, ?)": (v) => {
      if (this.identities.some((i) => i.provider === v[2] && i.subject === v[3])) return 0;
      this.identities.push({ id: v[0], user_id: v[1], provider: v[2], subject: v[3], email: v[4], created_at: v[5] });
      return 1;
    },
    "DELETE FROM auth_identities WHERE user_id = ?": (v) => this.del("identities", (i) => i.user_id === v[0]),
    // email codes
    "SELECT COUNT(*) AS n FROM email_codes WHERE email = ? AND created_at > ?": (v) => [
      { n: this.emailCodes.filter((c) => c.email === v[0] && t(c.created_at) > t(v[1])).length },
    ],
    "SELECT COUNT(*) AS n FROM email_codes WHERE ip = ? AND created_at > ?": (v) => [
      { n: this.emailCodes.filter((c) => c.ip === v[0] && t(c.created_at) > t(v[1])).length },
    ],
    "INSERT INTO email_codes (email, code_hash, ip, created_at, expires_at) VALUES (?, ?, ?, ?, ?)": (v) =>
      this.emailCodes.push({ id: String(++this.seq), email: v[0], code_hash: v[1], ip: v[2], attempts: 0, created_at: v[3], expires_at: v[4], consumed_at: null }) && 1,
    "SELECT id, code_hash FROM email_codes WHERE email = ? AND consumed_at IS NULL AND expires_at > ? ORDER BY id DESC LIMIT 1": (v) =>
      this.emailCodes
        .filter((c) => c.email === v[0] && c.consumed_at === null && t(c.expires_at) > t(v[1]))
        .sort((a, b) => Number(b.id) - Number(a.id))
        .slice(0, 1),
    "UPDATE email_codes SET attempts = attempts + 1 WHERE id = ? AND attempts < ? AND consumed_at IS NULL": (v) => {
      const c = this.emailCodes.find((c) => c.id === v[0] && Number(c.attempts) < Number(v[1]) && c.consumed_at === null);
      if (!c) return 0;
      c.attempts = Number(c.attempts) + 1;
      return 1;
    },
    "UPDATE email_codes SET consumed_at = ? WHERE id = ? AND consumed_at IS NULL": (v) =>
      this.update(this.emailCodes, (c) => c.id === v[1] && c.consumed_at === null, { consumed_at: v[0] }),
    "DELETE FROM email_codes WHERE email = ?": (v) => this.del("emailCodes", (c) => c.email === v[0]),
    // refresh tokens
    "INSERT INTO refresh_tokens (id, user_id, token_hash, created_at, expires_at) VALUES (?, ?, ?, ?, ?)": (v) =>
      this.refreshTokens.push({ id: v[0], user_id: v[1], token_hash: v[2], created_at: v[3], expires_at: v[4], revoked_at: null }) && 1,
    "SELECT id, user_id, revoked_at, expires_at FROM refresh_tokens WHERE token_hash = ?": (v) =>
      this.refreshTokens.filter((r) => r.token_hash === v[0]),
    "UPDATE refresh_tokens SET revoked_at = ? WHERE id = ? AND revoked_at IS NULL": (v) =>
      this.update(this.refreshTokens, (r) => r.id === v[1] && r.revoked_at === null, { revoked_at: v[0] }),
    "UPDATE refresh_tokens SET revoked_at = ? WHERE token_hash = ? AND revoked_at IS NULL": (v) =>
      this.update(this.refreshTokens, (r) => r.token_hash === v[1] && r.revoked_at === null, { revoked_at: v[0] }),
    "UPDATE refresh_tokens SET revoked_at = ? WHERE user_id = ? AND revoked_at IS NULL": (v) =>
      this.update(this.refreshTokens, (r) => r.user_id === v[1] && r.revoked_at === null, { revoked_at: v[0] }),
    "DELETE FROM refresh_tokens WHERE user_id = ?": (v) => this.del("refreshTokens", (r) => r.user_id === v[0]),
    // hosts
    "SELECT * FROM hosts WHERE id = ?": (v) => this.hosts.filter((h) => h.id === v[0]),
    "SELECT * FROM hosts WHERE id = ? AND user_id = ?": (v) => this.hosts.filter((h) => h.id === v[0] && h.user_id === v[1]),
    "SELECT * FROM hosts WHERE token_hash = ?": (v) => this.hosts.filter((h) => h.token_hash === v[0]),
    "SELECT * FROM hosts WHERE user_id = ? AND token_hash IS NOT NULL ORDER BY created_at": (v) =>
      this.hosts.filter((h) => h.user_id === v[0] && h.token_hash !== null),
    "INSERT INTO hosts (id, user_id, name, platform, app_version, token_hash, created_at, last_seen_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)": (v) =>
      this.hosts.push({ id: v[0], user_id: v[1], name: v[2], platform: v[3], app_version: v[4], token_hash: v[5], created_at: v[6], last_seen_at: v[7] }) && 1,
    "UPDATE hosts SET last_seen_at = ? WHERE id = ? AND (last_seen_at IS NULL OR last_seen_at < ?)": (v) =>
      this.update(this.hosts, (h) => h.id === v[1] && (h.last_seen_at === null || t(h.last_seen_at) < t(v[2])), { last_seen_at: v[0] }),
    "UPDATE hosts SET name = ? WHERE id = ?": (v) => this.update(this.hosts, (h) => h.id === v[1], { name: v[0] }),
    "DELETE FROM hosts WHERE id = ?": (v) => this.del("hosts", (h) => h.id === v[0]),
    "DELETE FROM hosts WHERE user_id = ?": (v) => this.del("hosts", (h) => h.user_id === v[0]),
    // pairings
    "SELECT COUNT(*) AS n FROM pairings WHERE ip = ? AND created_at > ?": (v) => [
      { n: this.pairings.filter((p) => p.ip === v[0] && t(p.created_at) > t(v[1])).length },
    ],
    "SELECT id FROM pairings WHERE code = ? AND status IN ('pending', 'awaiting_approval', 'approved') AND expires_at > ?": (v) =>
      this.pairings.filter((p) => p.code === v[0] && ["pending", "awaiting_approval", "approved"].includes(p.status as string) && t(p.expires_at) > t(v[1])),
    "INSERT INTO pairings (id, code, poll_secret_hash, host_name, platform, app_version, status, ip, created_at, expires_at) VALUES (?, ?, ?, ?, ?, ?, 'pending', ?, ?, ?)": (v) =>
      this.pairings.push({
        id: v[0], code: v[1], poll_secret_hash: v[2], host_name: v[3], platform: v[4], app_version: v[5],
        status: "pending", user_id: null, host_id: null, ip: v[6], created_at: v[7], expires_at: v[8],
      }) && 1,
    "SELECT * FROM pairings WHERE code = ? AND status = 'pending' AND expires_at > ? ORDER BY created_at DESC LIMIT 1": (v) =>
      this.pairings.filter((p) => p.code === v[0] && p.status === "pending" && t(p.expires_at) > t(v[1])).slice(-1),
    "SELECT * FROM pairings WHERE id = ?": (v) => this.pairings.filter((p) => p.id === v[0]),
    "UPDATE pairings SET status = 'awaiting_approval', user_id = ?, host_id = ? WHERE id = ? AND status = 'pending' AND user_id IS NULL": (v) =>
      this.update(this.pairings, (p) => p.id === v[2] && p.status === "pending" && p.user_id === null, { status: "awaiting_approval", user_id: v[0], host_id: v[1] }),
    "UPDATE pairings SET status = 'approved', expires_at = ? WHERE id = ? AND status = 'awaiting_approval'": (v) =>
      this.update(this.pairings, (p) => p.id === v[1] && p.status === "awaiting_approval", { status: "approved", expires_at: v[0] }),
    "UPDATE pairings SET status = 'completed' WHERE id = ? AND status = 'approved'": (v) =>
      this.update(this.pairings, (p) => p.id === v[0] && p.status === "approved", { status: "completed" }),
    "UPDATE pairings SET status = 'rejected' WHERE id = ? AND status IN ('pending', 'awaiting_approval')": (v) =>
      this.update(this.pairings, (p) => p.id === v[0] && (p.status === "pending" || p.status === "awaiting_approval"), { status: "rejected" }),
    "DELETE FROM pairings WHERE user_id = ?": (v) => this.del("pairings", (p) => p.user_id === v[0]),
    // rate events
    "SELECT COUNT(*) AS n FROM rate_events WHERE bucket = ? AND k = ? AND created_at > ?": (v) => [
      { n: this.rateEvents.filter((e) => e.bucket === v[0] && e.k === v[1] && t(e.created_at) > t(v[2])).length },
    ],
    "INSERT INTO rate_events (bucket, k, created_at) VALUES (?, ?, ?)": (v) =>
      this.rateEvents.push({ bucket: v[0], k: v[1], created_at: v[2] }) && 1,
    "DELETE FROM rate_events WHERE created_at < ? LIMIT 1000": (v) => this.del("rateEvents", (e) => t(e.created_at) < t(v[0])),
  };

  private update(table: Row[], pred: (r: Row) => boolean, set: Row): number {
    let n = 0;
    for (const r of table) if (pred(r)) (Object.assign(r, set), n++);
    return n;
  }

  private del(name: "users" | "identities" | "emailCodes" | "refreshTokens" | "hosts" | "pairings" | "rateEvents", pred: (r: Row) => boolean): number {
    const before = this[name].length;
    this[name] = this[name].filter((r) => !pred(r));
    return before - this[name].length;
  }

  private run(sql: string, values: V = []): Row[] | number {
    this.calls.push(sql);
    const h = this.handlers[sql];
    if (!h) throw new Error(`FakeDb: unhandled SQL: ${sql}`);
    return h(values);
  }

  async rows<T>(sql: string, values?: V): Promise<T[]> {
    return (this.run(sql, values) as Row[]).map(out) as T[];
  }
  async one<T>(sql: string, values?: V): Promise<T | null> {
    const r = this.run(sql, values) as Row[];
    return (r[0] ? out(r[0]) : null) as T | null;
  }
  async exec(sql: string, values?: V): Promise<{ rowsAffected: number }> {
    return { rowsAffected: this.run(sql, values) as number };
  }
}
