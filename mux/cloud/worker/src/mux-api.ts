import type { MuxApiMethods } from "@mux/brain";
import type { ID, LinkMethod, LinkMethods } from "@mux/protocol";
import { WorkerEntrypoint } from "cloudflare:workers";
import type { AgentOrigin } from "./account.ts";
import { account, conversation, type Env } from "./env.ts";

export interface MuxApiProps {
  muxId: ID;
  ownerId: ID;
  conversationId: ID;
}

/**
 * The `mux` API that code-mode sandboxes call. Props fix which mux, owner and
 * conversation a sandbox acts for; the sandbox never sees them.
 */
export class MuxApi extends WorkerEntrypoint<Env, MuxApiProps> implements MuxApiMethods {
  private get origin(): AgentOrigin {
    return { muxId: this.ctx.props.muxId, conversationId: this.ctx.props.conversationId };
  }

  /** A link call on the owner's machine, typed by method (RPC stubs erase result types). */
  private async call<M extends LinkMethod>(
    machine: string | undefined,
    method: M,
    params: LinkMethods[M]["params"],
    origin?: AgentOrigin,
  ): Promise<LinkMethods[M]["result"]> {
    const owner = account(this.env, this.ctx.props.ownerId);
    return (await owner.linkCall(machine, method, params, origin)) as LinkMethods[M]["result"];
  }

  async machinesList() {
    const machines = await account(this.env, this.ctx.props.ownerId).listMachines();
    return machines.map(({ id, name, os, online }) => ({ id, name, os, online }));
  }

  async agentsList({ machine }: { machine?: string }) {
    return (await this.call(machine, "agents.list", {})).agents;
  }

  async agentsHarnesses({ machine }: { machine?: string }) {
    return this.call(machine, "agents.harnesses", {});
  }

  async agentsSpawn({ machine, ...params }: Parameters<MuxApiMethods["agentsSpawn"]>[0]) {
    return this.call(machine, "agents.spawn", params, this.origin);
  }

  async agentsPrompt({ machine, ...params }: Parameters<MuxApiMethods["agentsPrompt"]>[0]) {
    return this.call(machine, "agents.prompt", params, this.origin);
  }

  async agentsLast({ machine, ...params }: Parameters<MuxApiMethods["agentsLast"]>[0]) {
    return this.call(machine, "agents.last", params);
  }

  async agentsCancel({ machine, ...params }: Parameters<MuxApiMethods["agentsCancel"]>[0]) {
    return this.call(machine, "agents.cancel", params);
  }

  async messagesSend(text: string) {
    await conversation(this.env, this.ctx.props.conversationId).post(this.ctx.props.muxId, [
      { type: "text", text },
    ]);
  }
}
