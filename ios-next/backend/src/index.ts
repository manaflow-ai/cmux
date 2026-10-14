import { createApp } from "./app";
import type { AppEnv } from "./env";

export { SignalRoom } from "./signal/room";

const app = createApp();

export default {
  fetch: (request, env, ctx) => app.fetch(request, env, ctx),
} satisfies ExportedHandler<AppEnv>;
