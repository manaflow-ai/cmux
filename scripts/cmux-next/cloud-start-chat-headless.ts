/**
 * One headless `cmux cloud start-chat` on staging with no cmux app (cmux#55501): the direct route
 * a lane VM takes. Lane starts required a GUI sign-in; this proves they no longer do.
 *
 * Signs in as the agent test account (CMUX_DOGFOOD_STACK_EMAIL/_PASSWORD, Stack password sign-in),
 * then runs CMUX_PATH `cloud start-chat --name cmux-test-headless-RUN --no-focus --json` twice with
 * CMUX_CLOUD_ACCESS_TOKEN and CMUX_CLOUD_API_URL in the environment and no --app-socket: the first
 * makes the machine and starts a chat, the second must take the same machine (no second one).
 * The token goes only in the child's environment and is scrubbed from everything printed. The
 * machine is deleted when the check ends, pass or fail: the platform's 6 h reap of cmux-test- names
 * was too slow, and one leaked machine per run filled staging's 300-machine team limit (hq#23807).
 */
import { spawnSync } from "node:child_process";
import { Api, passwordSignIn, resolveBackend, scrub, STACK } from "./cloud-journey.ts";

const env = process.env;
let made: string | undefined;
let cleanup = async () => {};
const fail = async (why: string): Promise<never> => {
  console.error(`headless start-chat: FAIL: ${why}`);
  await cleanup();
  process.exit(1);
};
const cmux = env.CMUX_PATH || (await fail("CMUX_PATH (this pull request's cmux-tui) is not set"));
const email = env.CMUX_DOGFOOD_STACK_EMAIL;
const password = env.CMUX_DOGFOOD_STACK_PASSWORD;
if (!email || !password) await fail("no CMUX_DOGFOOD_STACK_EMAIL/_PASSWORD (the agent test account)");
const backend = resolveBackend(env.TARGET || "staging");
const { access } = await passwordSignIn(STACK[backend.stack], email!, password!);
const secrets = [password!, access];
const name = `cmux-test-headless-${env.GITHUB_RUN_ID || Date.now()}`;
const api = new Api(backend.api);
api.bearer = access;
cleanup = async () => {
  if (!made) return;
  const id = made;
  made = undefined;
  await api.deleteMachine(id, `${name}-delete-${id}`).then(
    () => console.log(`headless start-chat: deleted ${id}`),
    (e: Error) => console.error(`headless start-chat: ${id} NOT deleted: ${scrub(e.message, secrets)}`),
  );
};

async function start(label: string): Promise<Record<string, unknown>> {
  const t0 = Date.now();
  const r = spawnSync(cmux, ["cloud", "start-chat", "--name", name, "--no-focus", "--json"], {
    env: { ...env, CMUX_CLOUD_ACCESS_TOKEN: access, CMUX_CLOUD_API_URL: backend.api, CMUX_DOGFOOD_STACK_PASSWORD: "" },
    encoding: "utf8",
    timeout: 600_000,
  });
  const out = scrub(r.stdout ?? "", secrets);
  const err = scrub(r.stderr ?? "", secrets);
  console.log(`headless start-chat (${label}): exit ${r.status} in ${Date.now() - t0} ms`);
  if (r.status !== 0) await fail(`${label} exited ${r.status}: ${err.slice(-1500) || out.slice(-1500)}`);
  let answer: any;
  try {
    answer = JSON.parse(out);
  } catch {
    await fail(`${label} answered no JSON: ${out.slice(-800)}`);
  }
  const result = answer?.result ?? answer;
  if (typeof result?.machine_id === "string") made = result.machine_id;
  if (typeof result?.machine_id !== "string" || typeof result?.session_id !== "string") {
    await fail(`${label} answered no machine_id/session_id: ${out.slice(-800)}`);
  }
  console.log(JSON.stringify({ machine_id: result.machine_id, machine_name: result.machine_name, session_id: result.session_id, follow_up: result.follow_up }, null, 2));
  return result;
}

const first = await start("new machine");
const again = await start("same name again");
if (again.machine_id !== first.machine_id) {
  // Both are this run's: delete the second one too.
  const second = String(again.machine_id);
  await api.deleteMachine(second, `${name}-delete-${second}`).catch(() => undefined);
  made = String(first.machine_id);
  await fail(`the second start took ${second}, not ${first.machine_id}`);
}
console.log(`headless start-chat: PASS (${backend.name}, machine ${first.machine_id})`);
await cleanup();
