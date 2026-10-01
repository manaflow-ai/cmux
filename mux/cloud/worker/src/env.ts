import type { AccountDO } from "./account.ts";
import type { ConversationDO } from "./conversation.ts";
import type { MuxDO } from "./mux.ts";

export interface Env {
  ACCOUNT: DurableObjectNamespace<AccountDO>;
  CONVERSATION: DurableObjectNamespace<ConversationDO>;
  MUX: DurableObjectNamespace<MuxDO>;
  LOADER: WorkerLoader;
  /** "1" accepts the `dev_user` query parameter as identity. Never set in staging. */
  MUX_DEV_AUTH?: string;
  /** Stack Auth project whose access tokens sign humans in. */
  MUX_STACK_PROJECT_ID?: string;
  /** Stack publishable client key, served to the web app for sign-in. */
  MUX_STACK_PUBLISHABLE_CLIENT_KEY?: string;
  CODEROUTER_API_KEY?: string;
  CODEROUTER_BASE_URL?: string;
}

export const account = (env: Env, userId: string) =>
  env.ACCOUNT.get(env.ACCOUNT.idFromName(userId));
export const conversation = (env: Env, id: string) =>
  env.CONVERSATION.get(env.CONVERSATION.idFromName(id));
export const mux = (env: Env, id: string) => env.MUX.get(env.MUX.idFromName(id));
