type DraftClient = {
  readDraft(sessionId: string): Promise<unknown>;
  writeDraft(sessionId: string, text: string): Promise<unknown>;
};
type Native = (method: string, params: Record<string, unknown>) => Promise<unknown>;

/** The page's draft actions: daemon state is shared by every host; native state is a fallback. */
export function draftTextActions(client: DraftClient, native: Native) {
  return {
    "chat.readDraft": async ({ sessionId }: Record<string, unknown>) => {
      const id = String(sessionId);
      const durable = await client.readDraft(id).catch(() => undefined);
      if (typeof durable === "string" && durable.length) return durable;
      const mirrored = await native("chat.draftText.get", { sessionId: id }).catch(() => undefined);
      return typeof mirrored === "string" && mirrored.length ? mirrored : durable;
    },
    "chat.writeDraft": async ({ sessionId, text }: Record<string, unknown>) => {
      const id = String(sessionId);
      const value = String(text ?? "");
      await native("chat.draftText.set", { sessionId: id, text: value }).catch(() => undefined);
      return client.writeDraft(id, value);
    },
  };
}
