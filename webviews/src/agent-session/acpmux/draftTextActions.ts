type DraftClient = {
  readDraft(sessionId: string): Promise<unknown>;
  writeDraft(sessionId: string, text: string): Promise<unknown>;
};
type Native = (method: string, params: Record<string, unknown>) => Promise<unknown>;

export function draftTextActions(client: DraftClient, native: Native) {
  const tails = new Map<string, Promise<unknown>>();
  const edits = new Map<string, { version: number; text: string }>();
  const known = new Map<string, { version: number; text: string }>();
  const ordered = (id: string, operation: () => Promise<unknown>) => {
    const next = (tails.get(id) ?? Promise.resolve()).catch(() => undefined).then(operation);
    tails.set(id, next);
    return next.finally(() => {
      if (tails.get(id) === next) tails.delete(id);
    });
  };

  return {
    "chat.readDraft": async ({ sessionId }: Record<string, unknown>) => {
      const id = String(sessionId),
        version = edits.get(id)?.version ?? 0;
      return ordered(id, async () => {
        const durable = await client.readDraft(id).catch(() => undefined);
        const newer = () => {
          const edit = edits.get(id);
          return edit && edit.version > version ? edit.text : undefined;
        };
        if (newer() !== undefined) return newer();
        const value =
          durable && typeof durable === "object" && "draft" in durable
            ? (durable as { draft?: unknown }).draft
            : typeof durable === "string"
              ? durable
              : undefined;
        if (typeof value === "string" || value === null) {
          const text = value ?? "";
          known.set(id, { version, text });
          await native("chat.draftText.set", { sessionId: id, text }).catch(() => undefined);
          return newer() ?? durable;
        }
        const retained = known.get(id);
        if (retained && retained.version >= version) return retained.text;
        const mirrored = await native("chat.draftText.get", { sessionId: id }).catch(() => undefined);
        return newer() ?? (typeof mirrored === "string" ? mirrored : durable);
      });
    },
    "chat.writeDraft": ({ sessionId, text }: Record<string, unknown>) => {
      const id = String(sessionId),
        value = String(text ?? ""),
        version = (edits.get(id)?.version ?? 0) + 1;
      edits.set(id, { version, text: value });
      known.set(id, { version, text: value });
      return ordered(id, async () => {
        await native("chat.draftText.set", { sessionId: id, text: value }).catch(() => undefined);
        return client.writeDraft(id, value);
      });
    },
  };
}
