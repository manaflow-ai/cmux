import { randomToken } from "./protocol";

export interface SessionMetadata {
  sessionID: string;
  sessionCode: string;
  token: string;
}

export interface SessionMetadataStorage {
  get<T>(key: string): Promise<T | undefined>;
  put<T>(key: string, value: T): Promise<void>;
}

const METADATA_KEY = "metadata";

export async function createSessionMetadata(
  storage: SessionMetadataStorage,
  sessionCode: string
): Promise<SessionMetadata> {
  const existing = await readSessionMetadata(storage);
  if (existing) return existing;

  const metadata = {
    sessionID: sessionCode,
    sessionCode,
    token: randomToken(),
  };
  await storage.put(METADATA_KEY, metadata);
  return metadata;
}

export async function readSessionMetadata(storage: SessionMetadataStorage): Promise<SessionMetadata | null> {
  return await storage.get<SessionMetadata>(METADATA_KEY) ?? null;
}
