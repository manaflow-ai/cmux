/// One current rule of this Mac's acpmux forum (`_acpmux/forum/rules`, hq#2570): the newest
/// announcement of its key. A person's rule is an instruction to every agent; an agent's is
/// information.
export type ForumRule = {
  id: string;
  key: string;
  body: string;
  author: { kind: "person"; account: string } | { kind: "agent"; sessionId: string; name: string };
  created: number;
  acks: { sessionId: string; at: number }[];
};

/// The rules in a `_acpmux/forum/rules` reply; malformed rows are left out.
export function forumRules(reply: unknown): ForumRule[] {
  const rows = (reply as { rules?: unknown } | null)?.rules;
  if (!Array.isArray(rows)) return [];
  return rows.flatMap((row): ForumRule[] => {
    if (!row || typeof row !== "object") return [];
    const r = row as Record<string, unknown>;
    const author = r.author as Record<string, unknown> | null | undefined;
    if (
      typeof r.id !== "string" ||
      typeof r.key !== "string" ||
      typeof r.body !== "string" ||
      !author ||
      typeof author !== "object"
    )
      return [];
    const who =
      author.kind === "person" && typeof author.account === "string"
        ? { kind: "person" as const, account: author.account }
        : author.kind === "agent" && typeof author.name === "string"
          ? { kind: "agent" as const, sessionId: String(author.sessionId ?? ""), name: author.name }
          : undefined;
    if (!who) return [];
    const acks = (Array.isArray(r.acks) ? r.acks : []).flatMap((ack): ForumRule["acks"] => {
      const a = ack as Record<string, unknown> | null;
      return a && typeof a.sessionId === "string" ? [{ sessionId: a.sessionId, at: Number(a.at ?? 0) }] : [];
    });
    return [{ id: r.id, key: r.key, body: r.body, author: who, created: Number(r.created ?? 0), acks }];
  });
}
