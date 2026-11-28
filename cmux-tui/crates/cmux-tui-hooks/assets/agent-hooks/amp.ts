const appendEvent = journalPlugin("amp");

function emit(nativeEvent: string, event: unknown, context: any) {
  return appendEvent(nativeEvent, { event, context: { thread: context?.thread, cwd: process.cwd() } });
}

export default function cmuxTuiJournal(amp: any) {
  amp.on("session.start", async (event: unknown, context: any) => {
    return emit("session.start", event, context);
  });
  amp.on("agent.start", async (event: unknown, context: any) => {
    return emit("agent.start", event, context);
  });
  amp.on("tool.call", async (event: unknown, context: any) => {
    emit("tool.call", event, context);
    return { action: "allow" as const };
  });
  amp.on("tool.result", async (event: unknown, context: any) => {
    return emit("tool.result", event, context);
  });
  amp.on("agent.end", async (event: unknown, context: any) => {
    return emit("agent.end", event, context);
  });
}
