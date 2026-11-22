import { AcpmuxClient, type McpServer, type SessionSummary } from "./acpmux-client.ts";
import { MUX_SESSION_NAME } from "./host.ts";
import { PARENT_TAG, type PermissionOption } from "./supervisor.ts";

// `mux agents ...`, run by the mux from its shell. Each verb is one short
// acpmux connection; the brain host (watching acpmux) turns the child's
// lifecycle into work cards and [mux-event] prompts, so nothing here waits for
// a child's turn to end.

/** Sends a prompt and returns once acpmux recorded it (user_message or queued), not when the turn ends. */
export async function promptAccepted(client: AcpmuxClient, sessionId: string, text: string): Promise<string> {
  const promptId = `mux-cli-${crypto.randomUUID()}`;
  const attached = await client.attach(sessionId, 0, 1);
  const id = attached.session.sessionId;
  const accepted = new Promise<void>((resolve, reject) => {
    const stop = client.onNotification((n) => {
      if (n.method !== "_acpmux/event" || n.params.sessionId !== id) return;
      const msg = (n.params.msg ?? {}) as { promptId?: string };
      if ((n.params.kind === "user_message" || n.params.kind === "queued") && msg.promptId === promptId) {
        stop();
        resolve();
      }
    });
    client.onClose(() => reject(new Error("acpmux connection closed before the prompt was accepted")));
  });
  const settled = client.prompt(id, text, { promptId, delivery: "turn" }).then(() => undefined);
  await Promise.race([accepted, settled]);
  return promptId;
}

export async function spawnAgent(
  socket: string,
  options: { cwd: string; prompt: string; name?: string; harness?: string; policy?: string; mcpServers?: McpServer[] },
): Promise<SessionSummary> {
  const client = await AcpmuxClient.connect(socket, "mux-agents");
  try {
    // A named session from a failed earlier start is reused.
    const existing = options.name ? (await client.sessions()).find((s) => s.name === options.name) : undefined;
    const sessionId =
      existing?.sessionId ??
      (
        await client.newSession({
          cwd: options.cwd,
          name: options.name,
          harness: options.harness,
          policy: options.policy,
          mcpServers: options.mcpServers,
        })
      ).sessionId;
    const tagged = await client.tag(sessionId, { [PARENT_TAG]: MUX_SESSION_NAME });
    await promptAccepted(client, sessionId, options.prompt);
    return tagged;
  } finally {
    client.close();
  }
}

export async function listAgents(socket: string): Promise<SessionSummary[]> {
  const client = await AcpmuxClient.connect(socket, "mux-agents");
  try {
    return (await client.sessions()).filter((s) => s.tags?.[PARENT_TAG] === MUX_SESSION_NAME);
  } finally {
    client.close();
  }
}

async function child(client: AcpmuxClient, name: string): Promise<SessionSummary> {
  const found = (await client.sessions()).find(
    (s) => (s.name === name || s.sessionId === name) && s.tags?.[PARENT_TAG] === MUX_SESSION_NAME,
  );
  if (!found) throw new Error(`no agent ${name} started by the mux (see \`mux agents list\`)`);
  return found;
}

export async function promptAgent(socket: string, name: string, text: string): Promise<void> {
  const client = await AcpmuxClient.connect(socket, "mux-agents");
  try {
    await promptAccepted(client, (await child(client, name)).sessionId, text);
  } finally {
    client.close();
  }
}

/**
 * Answers the agent's oldest pending permission. `allow` picks `optionId` (or
 * the first allow option); deny picks a reject option, else cancels.
 */
export async function answerPermission(
  socket: string,
  name: string,
  decision: { allow: true; optionId?: string } | { allow: false },
): Promise<string> {
  const client = await AcpmuxClient.connect(socket, "mux-agents");
  try {
    const session = await child(client, name);
    const info = await client.info(session.sessionId);
    const pending = info.pending?.[0];
    if (!pending) throw new Error(`${name} has no pending permission`);
    const options = (pending.request.options ?? []) as PermissionOption[];
    const optionId = decision.allow
      ? (decision.optionId ?? options.find((o) => o.kind?.startsWith("allow"))?.optionId ?? options[0]?.optionId)
      : options.find((o) => o.kind?.startsWith("reject"))?.optionId;
    await client.respondPermission(session.sessionId, pending.permissionId, optionId);
    return optionId ?? "(cancelled)";
  } finally {
    client.close();
  }
}
