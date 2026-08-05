import { randomBytes } from "node:crypto";
import {
  ExecError,
  SpritesClient,
  type Checkpoint,
  type ServiceLogEvent,
  type Sprite,
} from "@fly/sprites";
import {
  NotImplementedError,
  ProviderError,
  type AttachEndpoint,
  type CreateOptions,
  type ExecResult,
  type SnapshotRef,
  type SSHEndpoint,
  type VMHandle,
  type VMProvider,
  type VMStatus,
} from "./types";
import { withVmSpan } from "../telemetry";

const EXEC_MAX_BUFFER_BYTES = 10 * 1024 * 1024;
const REMOTE_STATE_DIR = "/home/sprite/.local/share/cmux-sprite/remote";
const SERVICE_NAME = "cmux-tui";

function client(): SpritesClient {
  const token = process.env.SPRITE_TOKEN?.trim() || process.env.SPRITES_TOKEN?.trim();
  if (!token) {
    throw new ProviderError("sprites", "SPRITE_TOKEN is required");
  }
  return new SpritesClient(token, {
    baseURL: process.env.SPRITES_API_URL?.trim() || undefined,
    timeout: 30_000,
  });
}

function spriteName(): string {
  return `cmux-${randomBytes(9).toString("hex")}`;
}

function shellQuote(value: string): string {
  return `'${value.replaceAll("'", `'\\''`)}'`;
}

export function mapStatus(status: string | undefined): VMStatus {
  switch (status) {
    case "creating":
    case "warming":
      return "creating";
    case "destroyed":
    case "deleted":
      return "destroyed";
    case "paused":
    case "cold":
    case "warm":
    case "running":
      // A paused Sprite remains immediately addressable and wakes on the next
      // exec or URL request, so it is an active Cloud VM from cmux's perspective.
      return "running";
    default:
      throw new ProviderError("sprites", "unsupported lifecycle status");
  }
}

async function drain(stream: AsyncIterable<unknown>): Promise<void> {
  for await (const event of stream) {
    void event;
  }
}

export async function waitForServiceStarted(
  stream: AsyncIterable<ServiceLogEvent>,
): Promise<void> {
  for await (const event of stream) {
    if (event.type === "started") return;
    if (event.type === "error" || event.type === "exit" || event.type === "stopped") {
      throw new ProviderError("sprites", "cmux service failed during startup");
    }
  }
  throw new ProviderError("sprites", "cmux service ended before readiness");
}

export function checkpointMatchingComment(
  checkpoints: readonly Checkpoint[],
  comment: string,
): Checkpoint | undefined {
  return checkpoints.find((checkpoint) => checkpoint.comment === comment);
}

function bootstrapCommand(image: string): string {
  return [
    "set -euo pipefail",
    `npm install -g --omit=dev --no-audit --fund=false ${shellQuote(image)} >/tmp/cmux-install.log 2>&1`,
    "sudo ln -sf \"$(npm prefix -g)/bin/cmux\" /usr/local/bin/cmux",
    "/usr/local/bin/cmux --version",
    `install -d -m 700 ${shellQuote(REMOTE_STATE_DIR)}`,
  ].join("; ");
}

export class SpritesProvider implements VMProvider {
  readonly id = "sprites" as const;

  async create(options: CreateOptions): Promise<VMHandle> {
    const image = options.image.trim();
    if (!/^cmux@[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$/.test(image)) {
      throw new ProviderError("sprites", "create requires a pinned cmux npm package");
    }
    return withVmSpan(
      "cmux.vm.provider.create",
      {
        "cmux.vm.provider": "sprites",
        "cmux.vm.operation": "create",
        "cmux.vm.image": image,
      },
      async (span) => {
        const sprites = client();
        const name = spriteName();
        let sprite: Sprite | null = null;
        try {
          sprite = await sprites.createSprite(name, {
            labels: ["cmux"],
            runtime: "dev",
            urlSettings: { auth: "public" },
            waitForCapacity: true,
          });
          await sprite.execFile("bash", ["-lc", bootstrapCommand(image)], {
            maxBuffer: EXEC_MAX_BUFFER_BYTES,
          });
          const service = await sprite.createService(
            SERVICE_NAME,
            {
              cmd: "/usr/local/bin/cmux",
              args: [
                "daemon",
                "--session",
                "sprite",
                "--remote-ws",
                "0.0.0.0:8080",
                "--remote-ws-insecure-bind",
                "--remote-state-dir",
                REMOTE_STATE_DIR,
              ],
              dir: "/home/sprite",
              httpPort: 8080,
            },
          );
          await waitForServiceStarted(service);
          const refreshed = await sprites.getSprite(name);
          const url = refreshed.url;
          if (!url) throw new Error("Sprite create response omitted its URL");
          span.setAttribute("cmux.vm.id", name);
          return {
            provider: "sprites",
            providerVmId: name,
            status: "running",
            image,
            createdAt: Date.now(),
            providerMetadata: { url },
          };
        } catch (error) {
          if (sprite) await sprite.delete().catch(() => undefined);
          throw new ProviderError("sprites", `create(${name})`, error);
        }
      },
    );
  }

  async destroy(vmId: string): Promise<void> {
    try {
      await client().deleteSprite(vmId);
    } catch (error) {
      throw new ProviderError("sprites", `destroy(${vmId})`, error);
    }
  }

  async getStatus(vmId: string): Promise<VMStatus> {
    try {
      return mapStatus((await client().getSprite(vmId)).status);
    } catch (error) {
      throw new ProviderError("sprites", `getStatus(${vmId})`, error);
    }
  }

  async pause(): Promise<void> {
    // Sprites pause themselves when no command, session, or URL request is active.
  }

  async resume(vmId: string): Promise<VMHandle> {
    try {
      const sprite = await client().getSprite(vmId);
      return {
        provider: "sprites",
        providerVmId: vmId,
        status: mapStatus(sprite.status),
        image: "cmux:sprite",
        createdAt: sprite.createdAt?.getTime() ?? Date.now(),
        providerMetadata: sprite.url ? { url: sprite.url } : undefined,
      };
    } catch (error) {
      throw new ProviderError("sprites", `resume(${vmId})`, error);
    }
  }

  async exec(vmId: string, command: string): Promise<ExecResult> {
    try {
      const result = await client().sprite(vmId).execFile("bash", ["-lc", command], {
        maxBuffer: EXEC_MAX_BUFFER_BYTES,
      });
      return {
        exitCode: result.exitCode,
        stdout: String(result.stdout),
        stderr: String(result.stderr),
      };
    } catch (error) {
      if (error instanceof ExecError) {
        return {
          exitCode: error.exitCode,
          stdout: String(error.stdout),
          stderr: String(error.stderr),
        };
      }
      throw new ProviderError("sprites", `exec(${vmId})`, error);
    }
  }

  async snapshot(vmId: string, name?: string): Promise<SnapshotRef> {
    try {
      const sprite = client().sprite(vmId);
      const checkpointComment = `cmux-${randomBytes(16).toString("hex")}`;
      const stream = await sprite.createCheckpoint(checkpointComment);
      await drain(stream);
      const checkpoints = await sprite.listCheckpoints();
      const checkpoint = checkpointMatchingComment(checkpoints, checkpointComment);
      if (!checkpoint) throw new Error("Sprite checkpoint completed without a checkpoint id");
      return {
        id: `${vmId}:${checkpoint.id}`,
        createdAt: checkpoint.createTime.getTime(),
        name,
      };
    } catch (error) {
      throw new ProviderError("sprites", `snapshot(${vmId})`, error);
    }
  }

  async restore(snapshotId: string): Promise<VMHandle> {
    void snapshotId;
    throw new NotImplementedError(
      "sprites",
      "cross-Sprite checkpoint restore requires a provider fork API",
    );
  }

  async openAttach(): Promise<AttachEndpoint> {
    throw new NotImplementedError(
      "sprites",
      "use cmux-sprites connect for Noise enrollment",
    );
  }

  async openSSH(): Promise<SSHEndpoint> {
    throw new NotImplementedError("sprites", "SSH is not exposed by cmux-sprites");
  }

  async revokeSSHIdentity(): Promise<void> {
    // Sprites never mint SSH identities.
  }
}
