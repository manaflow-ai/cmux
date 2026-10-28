type DraftClient = {
  readDraft(sessionId: string): Promise<unknown>;
  writeDraft(sessionId: string, text: string): Promise<unknown>;
};
type Native = (method: string, params: Record<string, unknown>) => Promise<unknown>;

type DraftOperation = () => Promise<unknown>;

/** The page's draft actions: daemon state is shared by every host; native state is a fallback. */
export function draftTextActions(client: DraftClient, native: Native) {
  const tails = new Map<string, Promise<unknown>>();
  const versions = new Map<string, number>();
  const pending = new Map<string, { version: number; text: string }>();

  const enqueue = (sessionId: string, operation: DraftOperation) => {
    const previous = tails.get(sessionId) ?? Promise.resolve();
    const next = previous.catch(() => undefined).then(operation);
    tails.set(sessionId, next);
    return next.finally(() => {
      if (tails.get(sessionId) === next) tails.delete(sessionId);
    });
  };
  const advance = (sessionId: string, text: string) => {
    const version = (versions.get(sessionId) ?? 0) + 1;
    versions.set(sessionId, version);
    pending.set(sessionId, { version, text });
    return version;
  };

  return {
    "chat.readDraft": ({ sessionId }: Record<string, unknown>) => {
      const id = String(sessionId);
      const version = versions.get(id) ?? 0;
      return enqueue(id, async () => {
        const durable = await client.readDraft(id).catch(() => undefined);
        const newer = pending.get(id);
        if (newer && newer.version > version) return newer.text;
        if (durable && typeof durable === "object" && "draft" in durable) {
          // A daemon string or explicit null is authoritative, including a clear from another host.
          const draft = (durable as { draft?: unknown }).draft;
          if (typeof draft === "string" || draft === null) {
            const text = draft ?? "";
            await native("chat.draftText.set", { sessionId: id, text }).catch(() => undefined);
            const latest = pending.get(id);
            if (latest && latest.version > version) return latest.text;
            if ((versions.get(id) ?? 0) === version) pending.delete(id);
            return durable;
          }
        }
        if (typeof durable === "string") {
          await native("chat.draftText.set", { sessionId: id, text: durable }).catch(() => undefined);
          const latest = pending.get(id);
          if (latest && latest.version > version) return latest.text;
          if ((versions.get(id) ?? 0) === version) pending.delete(id);
          return durable;
        }
        const mirrored = await native("chat.draftText.get", { sessionId: id }).catch(() => undefined);
        const latest = pending.get(id);
        return latest && latest.version > version ? latest.text : typeof mirrored === "string" ? mirrored : durable;
      });
    },
    "chat.writeDraft": ({ sessionId, text }: Record<string, unknown>) => {
      const id = String(sessionId);
      const value = String(text ?? "");
      const version = advance(id, value);
      return enqueue(id, async () => {
        await native("chat.draftText.set", { sessionId: id, text: value }).catch(() => undefined);
        await client.writeDraft(id, value);
        if (pending.get(id)?.version === version) pending.delete(id);
        return undefined;
      });
    },
  };
}
