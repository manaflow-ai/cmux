/** Storage contract. Timestamps are ms since epoch. Secrets are stored hashed. */

export interface User {
  id: string;
  email: string | null;
  name: string | null;
  createdAt: number;
}

export interface EmailCode {
  nonce: string;
  email: string;
  codeHash: string;
  attempts: number;
  expiresAt: number;
  consumedAt: number | null;
  createdAt: number;
}

export interface RefreshToken {
  hash: string;
  userId: string;
  familyId: string;
  expiresAt: number;
  revokedAt: number | null;
  createdAt: number;
}

export interface Host {
  id: string;
  userId: string;
  name: string;
  os: string;
  tokenHash: string | null;
  lastSeenAt: number | null;
  createdAt: number;
}

export interface HostPairing {
  id: string;
  deviceCodeHash: string;
  userCode: string;
  name: string;
  os: string;
  userId: string | null;
  hostId: string | null;
  expiresAt: number;
  approvedAt: number | null;
  claimedAt: number | null;
  createdAt: number;
}

export interface OAuthCode {
  codeHash: string;
  userId: string;
  codeChallenge: string | null;
  expiresAt: number;
  consumedAt: number | null;
  createdAt: number;
}

export interface Repo {
  // users and identities
  getUser(id: string): Promise<User | null>;
  getUserByEmail(email: string): Promise<User | null>;
  createUser(user: User): Promise<void>;
  setUserName(id: string, name: string): Promise<void>;
  /** Deletes the user and every row that belongs to them. */
  deleteUser(id: string): Promise<void>;
  findIdentityUserId(provider: string, subject: string): Promise<string | null>;
  createIdentity(provider: string, subject: string, userId: string, email: string | null, now: number): Promise<void>;

  // email codes
  createEmailCode(code: EmailCode): Promise<void>;
  getEmailCode(nonce: string): Promise<EmailCode | null>;
  countEmailCodesSince(email: string, since: number): Promise<number>;
  /** Atomically bumps attempts if below `max`; returns false when the limit is reached. */
  incrementEmailCodeAttempts(nonce: string, max: number): Promise<boolean>;
  /** Marks the code consumed if it was not already; returns false if it was. */
  consumeEmailCode(nonce: string, now: number): Promise<boolean>;

  // refresh tokens
  createRefreshToken(token: RefreshToken): Promise<void>;
  getRefreshToken(hash: string): Promise<RefreshToken | null>;
  /** Revokes one token if still active; returns false if it was already revoked. */
  revokeRefreshToken(hash: string, now: number): Promise<boolean>;
  revokeRefreshFamily(familyId: string, now: number): Promise<void>;

  // hosts
  createHost(host: Host): Promise<void>;
  getHost(id: string): Promise<Host | null>;
  getHostByTokenHash(hash: string): Promise<Host | null>;
  listHosts(userId: string): Promise<Host[]>;
  /** Returns false when no host with that id belongs to the user. */
  deleteHost(id: string, userId: string): Promise<boolean>;
  setHostToken(id: string, tokenHash: string): Promise<void>;
  touchHost(id: string, at: number): Promise<void>;

  // host pairings
  createPairing(pairing: HostPairing): Promise<void>;
  getPairingByDeviceCodeHash(hash: string): Promise<HostPairing | null>;
  getPendingPairingByUserCode(userCode: string, now: number): Promise<HostPairing | null>;
  /** Approves a pending pairing; returns false if it was approved concurrently. */
  approvePairing(id: string, userId: string, hostId: string, now: number): Promise<boolean>;
  /** Marks an approved pairing claimed; returns false if it was already claimed. */
  claimPairing(id: string, now: number): Promise<boolean>;

  // oauth one-time codes
  createOAuthCode(code: OAuthCode): Promise<void>;
  /** Returns and consumes the code; null when unknown, expired or used. */
  takeOAuthCode(codeHash: string, now: number): Promise<OAuthCode | null>;
}
