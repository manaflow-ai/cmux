import { checkDockerStatus as checkDockerStatusShared } from "@cmux/shared/providers/common/check-docker";

export type DockerStatus = "ok" | "not_installed" | "not_running";

export async function checkDockerStatus(): Promise<DockerStatus> {
  const status = await checkDockerStatusShared();

  if (!status.isRunning) {
    if (status.error) {
      const errorLower = status.error.toLowerCase();
      if (
        errorLower.includes("not installed") ||
        errorLower.includes("not available in path") ||
        errorLower.includes("command not found")
      ) {
        return "not_installed";
      }
    }
    return "not_running";
  }

  return "ok";
}
