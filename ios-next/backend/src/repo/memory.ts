import { DuplicateError, type EmailCode, type Host, type HostPairing, type OAuthCode, type RefreshToken, type Repo, type User } from "./types";

/** In-process store for tests and local development. */
export class MemoryRepo implements Repo {
  users = new Map<string, User>();
  identities = new Map<string, { userId: string; email: string | null }>();
  emailCodes = new Map<string, EmailCode>();
  refreshTokens = new Map<string, RefreshToken>();
  hosts = new Map<string, Host>();
  pairings = new Map<string, HostPairing>();
  oauthCodes = new Map<string, OAuthCode>();

  async getUser(id: string) {
    return clone(this.users.get(id));
  }
  async getUserByEmail(email: string) {
    return clone([...this.users.values()].find((u) => u.email === email));
  }
  async createUser(user: User) {
    if (user.email && [...this.users.values()].some((u) => u.email === user.email)) throw new DuplicateError("duplicate email");
    this.users.set(user.id, { ...user });
  }
  async setUserName(id: string, name: string) {
    const u = this.users.get(id);
    if (u) u.name = name;
  }
  async deleteUser(id: string) {
    const user = this.users.get(id);
    this.users.delete(id);
    for (const [k, v] of this.identities) if (v.userId === id) this.identities.delete(k);
    for (const [k, v] of this.refreshTokens) if (v.userId === id) this.refreshTokens.delete(k);
    for (const [k, v] of this.hosts) if (v.userId === id) this.hosts.delete(k);
    for (const [k, v] of this.pairings) if (v.userId === id) this.pairings.delete(k);
    for (const [k, v] of this.oauthCodes) if (v.userId === id) this.oauthCodes.delete(k);
    if (user?.email) for (const [k, v] of this.emailCodes) if (v.email === user.email) this.emailCodes.delete(k);
  }
  async findIdentityUserId(provider: string, subject: string) {
    return this.identities.get(`${provider}:${subject}`)?.userId ?? null;
  }
  async createIdentity(provider: string, subject: string, userId: string, email: string | null) {
    if (this.identities.has(`${provider}:${subject}`)) throw new DuplicateError("duplicate identity");
    this.identities.set(`${provider}:${subject}`, { userId, email });
  }

  async createEmailCode(code: EmailCode) {
    this.emailCodes.set(code.nonce, { ...code });
  }
  async getEmailCode(nonce: string) {
    return clone(this.emailCodes.get(nonce));
  }
  async countEmailCodesSince(email: string, since: number) {
    return [...this.emailCodes.values()].filter((c) => c.email === email && c.createdAt >= since).length;
  }
  async incrementEmailCodeAttempts(nonce: string, max: number) {
    const c = this.emailCodes.get(nonce);
    if (!c || c.attempts >= max) return false;
    c.attempts++;
    return true;
  }
  async consumeEmailCode(nonce: string, now: number) {
    const c = this.emailCodes.get(nonce);
    if (!c || c.consumedAt !== null) return false;
    c.consumedAt = now;
    return true;
  }

  async createRefreshToken(token: RefreshToken) {
    this.refreshTokens.set(token.hash, { ...token });
  }
  async createRefreshTokenIfAbsent(token: RefreshToken) {
    if (this.refreshTokens.has(token.hash)) return false;
    this.refreshTokens.set(token.hash, { ...token });
    return true;
  }
  async markRefreshTokenRotated(hash: string, now: number) {
    const t = this.refreshTokens.get(hash);
    if (!t || t.revokedAt !== null) return false;
    t.revokedAt = now;
    t.rotatedAt = now;
    return true;
  }
  async getRefreshToken(hash: string) {
    return clone(this.refreshTokens.get(hash));
  }
  async revokeRefreshToken(hash: string, now: number) {
    const t = this.refreshTokens.get(hash);
    if (!t || t.revokedAt !== null) return false;
    t.revokedAt = now;
    return true;
  }
  async revokeRefreshFamily(familyId: string, now: number) {
    for (const t of this.refreshTokens.values()) if (t.familyId === familyId && t.revokedAt === null) t.revokedAt = now;
  }

  async listActiveRefreshFamilies(userId: string) {
    return [...new Set([...this.refreshTokens.values()].filter((t) => t.userId === userId && t.revokedAt === null).map((t) => t.familyId))];
  }

  async createHost(host: Host) {
    this.hosts.set(host.id, { ...host });
  }
  async getHost(id: string) {
    return clone(this.hosts.get(id));
  }
  async getHostByTokenHash(hash: string) {
    return clone([...this.hosts.values()].find((h) => h.tokenHash === hash));
  }
  async listHosts(userId: string) {
    return [...this.hosts.values()]
      .filter((h) => h.userId === userId)
      .sort((a, b) => a.createdAt - b.createdAt)
      .map((h) => ({ ...h }));
  }
  async deleteHost(id: string, userId: string) {
    const h = this.hosts.get(id);
    if (!h || h.userId !== userId) return false;
    this.hosts.delete(id);
    return true;
  }
  async setHostToken(id: string, tokenHash: string) {
    const h = this.hosts.get(id);
    if (h) h.tokenHash = tokenHash;
  }
  async touchHost(id: string, at: number) {
    const h = this.hosts.get(id);
    if (h) h.lastSeenAt = at;
  }

  async createPairing(p: HostPairing) {
    this.pairings.set(p.id, { ...p });
  }
  async getPairingByDeviceCodeHash(hash: string) {
    return clone([...this.pairings.values()].find((p) => p.deviceCodeHash === hash));
  }
  async getPendingPairingByUserCode(userCode: string, now: number) {
    return clone([...this.pairings.values()].find((p) => p.userCode === userCode && p.approvedAt === null && p.expiresAt > now));
  }
  async approvePairing(id: string, userId: string, hostId: string, now: number) {
    const p = this.pairings.get(id);
    if (!p || p.approvedAt !== null) return false;
    Object.assign(p, { userId, hostId, approvedAt: now });
    return true;
  }
  async claimPairing(id: string, now: number) {
    const p = this.pairings.get(id);
    if (!p || p.approvedAt === null || p.claimedAt !== null) return false;
    p.claimedAt = now;
    return true;
  }

  async createOAuthCode(code: OAuthCode) {
    this.oauthCodes.set(code.codeHash, { ...code });
  }
  async takeOAuthCode(codeHash: string, now: number) {
    const c = this.oauthCodes.get(codeHash);
    if (!c || c.consumedAt !== null || c.expiresAt <= now) return null;
    c.consumedAt = now;
    return { ...c };
  }
}

function clone<T extends object>(v: T | undefined): T | null {
  return v ? { ...v } : null;
}
