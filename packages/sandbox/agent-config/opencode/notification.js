import { spawn } from "node:child_process";

const runNotification = async (message) =>
  new Promise((resolve) => {
    const child = spawn("cmux-bridge", ["notify", message], {
      stdio: ["ignore", "pipe", "pipe"],
    });

    let stdout = "";
    let stderr = "";

    child.stdout?.on("data", (chunk) => {
      stdout += chunk.toString();
    });
    child.stderr?.on("data", (chunk) => {
      stderr += chunk.toString();
    });

    child.on("error", (error) => {
      resolve({ code: null, stdout, stderr, error });
    });

    child.on("close", (code) => {
      resolve({
        code,
        stdout: stdout.trim(),
        stderr: stderr.trim(),
        error: code === 0 ? undefined : new Error(`Exited with code ${code}`),
      });
    });
  });

// OpenCode notification plugin for cmux sandbox
// Sends notifications to cmux UI when agent becomes idle
export const NotificationPlugin = async ({ event: _ }) => {
  return {
    event: async ({ event }) => {
      const props = event?.properties ?? {};
      const statusType =
        props.status?.type ??
        props.status ??
        event?.status?.type ??
        event?.status;
      const isIdle =
        event.type === "session.idle" ||
        (event.type === "session.status" && statusType === "idle");

      if (isIdle) {
        try {
          const result = await runNotification("OpenCode awaiting input");
          if (result.error || result.code !== 0) {
            console.error(
              "OpenCode notification failed",
              result.error ?? `Exited with code ${result.code}`,
              { stdout: result.stdout, stderr: result.stderr }
            );
          }
        } catch (error) {
          console.error("OpenCode notification failed", error);
        }
      }
    },
  };
};
