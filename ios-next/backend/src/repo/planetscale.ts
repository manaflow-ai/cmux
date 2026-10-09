import { connect, type Connection } from "@planetscale/database";
import { format } from "sql-escaper";
import type { AppEnv } from "../env";
import type { EmailCode, Host, HostPairing, OAuthCode, RefreshToken, Repo, User } from "./types";

type Row = Record<string, unknown>;

const num = (v: unknown): number => Number(v);
const numOrNull = (v: unknown): number | null => (v === null || v === undefined ? null : Number(v));
const strOrNull = (v: unknown): string | null => (v === null || v === undefined ? null : String(v));

const toUser = (r: Row): User => ({ id: String(r.id), email: strOrNull(r.email), name: strOrNull(r.name), createdAt: num(r.created_at) });
const toEmailCode = (r: Row): EmailCode => ({
  nonce: String(r.nonce),
  email: String(r.email),
  codeHash: String(r.code_hash),
  attempts: num(r.attempts),
  expiresAt: num(r.expires_at),
  consumedAt: numOrNull(r.consumed_at),
  createdAt: num(r.created_at),
});
const toRefresh = (r: Row): RefreshToken => ({
  hash: String(r.hash),
  userId: String(r.user_id),
  familyId: String(r.family_id),
  expiresAt: num(r.expires_at),
  revokedAt: numOrNull(r.revoked_at),
  createdAt: num(r.created_at),
});
const toHost = (r: Row): Host => ({
  id: String(r.id),
  userId: String(r.user_id),
  name: String(r.name),
  os: String(r.os),
  tokenHash: strOrNull(r.token_hash),
  lastSeenAt: numOrNull(r.last_seen_at),
  createdAt: num(r.created_at),
});
const toPairing = (r: Row): HostPairing => ({
  id: String(r.id),
  deviceCodeHash: String(r.device_code_hash),
  userCode: String(r.user_code),
  name: String(r.name),
  os: String(r.os),
  userId: strOrNull(r.user_id),
  hostId: strOrNull(r.host_id),
  expiresAt: num(r.expires_at),
  approvedAt: numOrNull(r.approved_at),
  claimedAt: numOrNull(r.claimed_at),
  createdAt: num(r.created_at),
});
const toOAuthCode = (r: Row): OAuthCode => ({
  codeHash: String(r.code_hash),
  userId: String(r.user_id),
  codeChallenge: strOrNull(r.code_challenge),
  expiresAt: num(r.expires_at),
  consumedAt: numOrNull(r.consumed_at),
  createdAt: num(r.created_at),
});

/** PlanetScale (MySQL/Vitess) over the serverless HTTP driver. */
export class PlanetScaleRepo implements Repo {
  constructor(private readonly db: Connection) {}

  static fromEnv(env: AppEnv): PlanetScaleRepo {
    return new PlanetScaleRepo(
      connect({
        host: env.DATABASE_HOST,
        username: env.DATABASE_USERNAME,
        password: env.DATABASE_PASSWORD,
        // The driver passes `cache`, which some runtimes reject; drop it.
        fetch: (url, init) => {
          const { cache: _cache, ...rest } = (init ?? {}) as RequestInit & { cache?: unknown };
          return fetch(url, rest);
        },
      }),
    );
  }

  private async one(sql: string, args: unknown[]): Promise<Row | null> {
    const res = await this.db.execute(format(sql, args));
    return (res.rows[0] as Row | undefined) ?? null;
  }
  private async all(sql: string, args: unknown[]): Promise<Row[]> {
    const res = await this.db.execute(format(sql, args));
    return res.rows as Row[];
  }
  private async run(sql: string, args: unknown[]): Promise<number> {
    const res = await this.db.execute(format(sql, args));
    return res.rowsAffected;
  }

  async getUser(id: string) {
    const r = await this.one("SELECT * FROM users WHERE id = ?", [id]);
    return r ? toUser(r) : null;
  }
  async getUserByEmail(email: string) {
    const r = await this.one("SELECT * FROM users WHERE email = ?", [email]);
    return r ? toUser(r) : null;
  }
  async createUser(u: User) {
    await this.run("INSERT INTO users (id, email, name, created_at) VALUES (?, ?, ?, ?)", [u.id, u.email, u.name, u.createdAt]);
  }
  async setUserName(id: string, name: string) {
    await this.run("UPDATE users SET name = ? WHERE id = ?", [name, id]);
  }
  async deleteUser(id: string) {
    const user = await this.getUser(id);
    await this.db.transaction(async (tx) => {
      await tx.execute(format("DELETE FROM identities WHERE user_id = ?", [id]));
      await tx.execute(format("DELETE FROM refresh_tokens WHERE user_id = ?", [id]));
      await tx.execute(format("DELETE FROM hosts WHERE user_id = ?", [id]));
      await tx.execute(format("DELETE FROM host_pairings WHERE user_id = ?", [id]));
      await tx.execute(format("DELETE FROM oauth_codes WHERE user_id = ?", [id]));
      if (user?.email) await tx.execute(format("DELETE FROM email_codes WHERE email = ?", [user.email]));
      await tx.execute(format("DELETE FROM users WHERE id = ?", [id]));
    });
  }
  async findIdentityUserId(provider: string, subject: string) {
    const r = await this.one("SELECT user_id FROM identities WHERE provider = ? AND subject = ?", [provider, subject]);
    return r ? String(r.user_id) : null;
  }
  async createIdentity(provider: string, subject: string, userId: string, email: string | null, now: number) {
    await this.run("INSERT INTO identities (provider, subject, user_id, email, created_at) VALUES (?, ?, ?, ?, ?)", [provider, subject, userId, email, now]);
  }

  async createEmailCode(c: EmailCode) {
    await this.run(
      "INSERT INTO email_codes (nonce, email, code_hash, attempts, expires_at, consumed_at, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
      [c.nonce, c.email, c.codeHash, c.attempts, c.expiresAt, c.consumedAt, c.createdAt],
    );
  }
  async getEmailCode(nonce: string) {
    const r = await this.one("SELECT * FROM email_codes WHERE nonce = ?", [nonce]);
    return r ? toEmailCode(r) : null;
  }
  async countEmailCodesSince(email: string, since: number) {
    const r = await this.one("SELECT COUNT(*) AS n FROM email_codes WHERE email = ? AND created_at >= ?", [email, since]);
    return r ? num(r.n) : 0;
  }
  async incrementEmailCodeAttempts(nonce: string, max: number) {
    return (await this.run("UPDATE email_codes SET attempts = attempts + 1 WHERE nonce = ? AND attempts < ?", [nonce, max])) === 1;
  }
  async consumeEmailCode(nonce: string, now: number) {
    return (await this.run("UPDATE email_codes SET consumed_at = ? WHERE nonce = ? AND consumed_at IS NULL", [now, nonce])) === 1;
  }

  async createRefreshToken(t: RefreshToken) {
    await this.run(
      "INSERT INTO refresh_tokens (hash, user_id, family_id, expires_at, revoked_at, created_at) VALUES (?, ?, ?, ?, ?, ?)",
      [t.hash, t.userId, t.familyId, t.expiresAt, t.revokedAt, t.createdAt],
    );
  }
  async getRefreshToken(hash: string) {
    const r = await this.one("SELECT * FROM refresh_tokens WHERE hash = ?", [hash]);
    return r ? toRefresh(r) : null;
  }
  async revokeRefreshToken(hash: string, now: number) {
    return (await this.run("UPDATE refresh_tokens SET revoked_at = ? WHERE hash = ? AND revoked_at IS NULL", [now, hash])) === 1;
  }
  async revokeRefreshFamily(familyId: string, now: number) {
    await this.run("UPDATE refresh_tokens SET revoked_at = ? WHERE family_id = ? AND revoked_at IS NULL", [now, familyId]);
  }

  async createHost(h: Host) {
    await this.run(
      "INSERT INTO hosts (id, user_id, name, os, token_hash, last_seen_at, created_at) VALUES (?, ?, ?, ?, ?, ?, ?)",
      [h.id, h.userId, h.name, h.os, h.tokenHash, h.lastSeenAt, h.createdAt],
    );
  }
  async getHost(id: string) {
    const r = await this.one("SELECT * FROM hosts WHERE id = ?", [id]);
    return r ? toHost(r) : null;
  }
  async getHostByTokenHash(hash: string) {
    const r = await this.one("SELECT * FROM hosts WHERE token_hash = ?", [hash]);
    return r ? toHost(r) : null;
  }
  async listHosts(userId: string) {
    return (await this.all("SELECT * FROM hosts WHERE user_id = ? ORDER BY created_at", [userId])).map(toHost);
  }
  async deleteHost(id: string, userId: string) {
    return (await this.run("DELETE FROM hosts WHERE id = ? AND user_id = ?", [id, userId])) === 1;
  }
  async setHostToken(id: string, tokenHash: string) {
    await this.run("UPDATE hosts SET token_hash = ? WHERE id = ?", [tokenHash, id]);
  }
  async touchHost(id: string, at: number) {
    await this.run("UPDATE hosts SET last_seen_at = ? WHERE id = ?", [at, id]);
  }

  async createPairing(p: HostPairing) {
    await this.run(
      "INSERT INTO host_pairings (id, device_code_hash, user_code, name, os, user_id, host_id, expires_at, approved_at, claimed_at, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
      [p.id, p.deviceCodeHash, p.userCode, p.name, p.os, p.userId, p.hostId, p.expiresAt, p.approvedAt, p.claimedAt, p.createdAt],
    );
  }
  async getPairingByDeviceCodeHash(hash: string) {
    const r = await this.one("SELECT * FROM host_pairings WHERE device_code_hash = ?", [hash]);
    return r ? toPairing(r) : null;
  }
  async getPendingPairingByUserCode(userCode: string, now: number) {
    const r = await this.one(
      "SELECT * FROM host_pairings WHERE user_code = ? AND approved_at IS NULL AND expires_at > ? ORDER BY created_at DESC LIMIT 1",
      [userCode, now],
    );
    return r ? toPairing(r) : null;
  }
  async approvePairing(id: string, userId: string, hostId: string, now: number) {
    return (
      (await this.run("UPDATE host_pairings SET user_id = ?, host_id = ?, approved_at = ? WHERE id = ? AND approved_at IS NULL", [userId, hostId, now, id])) === 1
    );
  }
  async claimPairing(id: string, now: number) {
    return (await this.run("UPDATE host_pairings SET claimed_at = ? WHERE id = ? AND approved_at IS NOT NULL AND claimed_at IS NULL", [now, id])) === 1;
  }

  async createOAuthCode(c: OAuthCode) {
    await this.run(
      "INSERT INTO oauth_codes (code_hash, user_id, code_challenge, expires_at, consumed_at, created_at) VALUES (?, ?, ?, ?, ?, ?)",
      [c.codeHash, c.userId, c.codeChallenge, c.expiresAt, c.consumedAt, c.createdAt],
    );
  }
  async takeOAuthCode(codeHash: string, now: number) {
    const ok = (await this.run("UPDATE oauth_codes SET consumed_at = ? WHERE code_hash = ? AND consumed_at IS NULL AND expires_at > ?", [now, codeHash, now])) === 1;
    if (!ok) return null;
    const r = await this.one("SELECT * FROM oauth_codes WHERE code_hash = ?", [codeHash]);
    return r ? toOAuthCode(r) : null;
  }
}
