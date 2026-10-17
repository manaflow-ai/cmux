import { isAbsolute, resolve } from "node:path";
import { pathToFileURL } from "node:url";
import {
  createAgentBrokerWorker,
} from "../services/agent-broker/worker";
import type { AgentBrokerAdapterModule, AgentBrokerEffectAdapter } from "../services/agent-broker/adapterBoundary";

type WorkerHandle = ReturnType<typeof createAgentBrokerWorker>;

async function loadAdapters(): Promise<readonly AgentBrokerEffectAdapter[]> {
  const modulePath = process.env.CMUX_BROKER_ADAPTER_MODULE?.trim();
  if (!modulePath) return [];
  const url = pathToFileURL(isAbsolute(modulePath) ? modulePath : resolve(process.cwd(), modulePath)).href;
  const module = await import(url) as Partial<AgentBrokerAdapterModule>;
  if (typeof module.createAgentBrokerAdapters !== "function") {
    throw new Error("CMUX_BROKER_ADAPTER_MODULE must export createAgentBrokerAdapters");
  }
  return await module.createAgentBrokerAdapters({ env: process.env });
}

function workerId(): string {
  const value = process.env.CMUX_BROKER_WORKER_ID?.trim();
  if (value) return value;
  return `broker-worker:${process.pid}`;
}

function optionalPositiveInt(name: string): number | undefined {
  const raw = process.env[name]?.trim();
  if (!raw) return undefined;
  const value = Number(raw);
  if (!Number.isSafeInteger(value) || value < 1) throw new Error(`${name} must be a positive integer`);
  return value;
}

export async function createConfiguredAgentBrokerWorker(): Promise<WorkerHandle> {
  const adapters = await loadAdapters();
  return createAgentBrokerWorker({
    workerId: workerId(),
    hostClass: process.env.CMUX_BROKER_HOST_CLASS?.trim() || undefined,
    leaseTtlMs: optionalPositiveInt("CMUX_BROKER_LEASE_TTL_MS"),
    adapters,
  });
}

async function main(): Promise<void> {
  const worker = await createConfiguredAgentBrokerWorker();
  const once = process.env.CMUX_BROKER_ONCE === "1";
  if (once) {
    const result = await worker.runOnce();
    console.log(JSON.stringify(result));
    return;
  }
  const controller = new AbortController();
  const stop = () => controller.abort();
  process.once("SIGINT", stop);
  process.once("SIGTERM", stop);
  await worker.run({ signal: controller.signal, pollMs: optionalPositiveInt("CMUX_BROKER_POLL_MS") });
}

if (process.argv[1]?.endsWith("agent-broker-worker.ts")) await main();
