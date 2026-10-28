type DraftClient = {
  readDraft(sessionId: string): Promise<unknown>;
  writeDraft(sessionId: string, text: string): Promise<unknown>;
};
type Native = (method: string, params: Record<string, unknown>) => Promise<unknown>;

/** Daemon state is shared by every host; ordered native mirrors survive unavailable reads. */
export function draftTextActions(client: DraftClient, native: Native) {
  const tails = new Map<string, Promise<unknown>>();
  const edits = new Map<string, { version: number; text: string }>();
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
      const durable = await client.readDraft(id).catch(() => undefined);
      return ordered(id, async () => {
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
          await native("chat.draftText.set", { sessionId: id, text: value ?? "" }).catch(() => undefined);
          return newer() ?? durable;
        }
        const mirrored = await native("chat.draftText.get", { sessionId: id }).catch(() => undefined);
        return newer() ?? (typeof mirrored === "string" ? mirrored : durable);
      });
    },
    "chat.writeDraft": ({ sessionId, text }: Record<string, unknown>) => {
      const id = String(sessionId),
        value = String(text ?? "");
      edits.set(id, { version: (edits.get(id)?.version ?? 0) + 1, text: value });
      return ordered(id, async () => {
        await native("chat.draftText.set", { sessionId: id, text: value }).catch(() => undefined);
      }).then(() => client.writeDraft(id, value));
    },
  };
}
