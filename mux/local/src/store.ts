import { Database } from "bun:sqlite";
import type {
  Conversation,
  ConversationSummary,
  ID,
  Message,
  Part,
  Participant,
} from "@mux/protocol";

/** Conversations on this machine, in one SQLite file. */
export class LocalStore {
  private db: Database;

  constructor(path: string) {
    this.db = new Database(path, { create: true });
    this.db.exec(`
      PRAGMA journal_mode = WAL;
      CREATE TABLE IF NOT EXISTS conversations (
        id TEXT PRIMARY KEY, title TEXT NOT NULL, participants TEXT NOT NULL, updated INTEGER NOT NULL DEFAULT 0
      );
      CREATE TABLE IF NOT EXISTS messages (
        seq INTEGER PRIMARY KEY AUTOINCREMENT, conversation_id TEXT NOT NULL, id TEXT UNIQUE NOT NULL, json TEXT NOT NULL
      );
      CREATE INDEX IF NOT EXISTS messages_by_conversation ON messages (conversation_id, seq);
    `);
  }

  create(title: string, participants: Participant[]): Conversation {
    const id = crypto.randomUUID();
    this.db.run(
      "INSERT INTO conversations (id, title, participants, updated) VALUES (?, ?, ?, (SELECT COALESCE(MAX(updated), 0) + 1 FROM conversations))",
      [id, title, JSON.stringify(participants)],
    );
    return { id, title, participants, messages: [] };
  }

  get(id: ID): Conversation | undefined {
    const row = this.db
      .query<{ title: string; participants: string }, [string]>(
        "SELECT title, participants FROM conversations WHERE id = ?",
      )
      .get(id);
    if (!row) return undefined;
    const messages = this.db
      .query<{ json: string }, [string]>(
        "SELECT json FROM messages WHERE conversation_id = ? ORDER BY seq",
      )
      .all(id)
      .map((r) => JSON.parse(r.json) as Message);
    return {
      id,
      title: row.title,
      participants: JSON.parse(row.participants) as Participant[],
      messages,
    };
  }

  /** Newest activity first (a new conversation counts as activity). */
  list(): ConversationSummary[] {
    const rows = this.db
      .query<{ id: string; title: string; json: string | null }, []>(
        `SELECT c.id, c.title, m.json FROM conversations c
         LEFT JOIN messages m ON m.seq = (SELECT MAX(seq) FROM messages WHERE conversation_id = c.id)
         ORDER BY c.updated DESC`,
      )
      .all();
    return rows.map((row) => {
      const last = row.json ? (JSON.parse(row.json) as Message) : undefined;
      const part = last?.parts[0];
      return {
        id: row.id,
        title: row.title,
        preview: part?.type === "text" ? part.text : "",
        lastAt: last?.sentAt ?? "",
      };
    });
  }

  append(conversationId: ID, senderId: ID, parts: Part[]): Message {
    const message: Message = {
      id: crypto.randomUUID(),
      senderId,
      sentAt: new Date().toISOString(),
      parts,
      reactions: [],
    };
    this.db.run("INSERT INTO messages (conversation_id, id, json) VALUES (?, ?, ?)", [
      conversationId,
      message.id,
      JSON.stringify(message),
    ]);
    this.db.run(
      "UPDATE conversations SET updated = (SELECT MAX(updated) + 1 FROM conversations) WHERE id = ?",
      [conversationId],
    );
    return message;
  }
}
