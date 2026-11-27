// Settings > Cloud > Default Image (`cloud.defaultImage`, PR https://github.com/manaflow-ai/cmux/pull/51769):
// the composer no longer picks a Cloud environment, so a new Cloud chat starts from the setting. The
// host sends the key with the chat's display keys (Swift AgentPaneDisplaySetting.followedAppPaths);
// useChatCloudEnvironment holds it as the chat's pick until the chat picks its own.
import { afterEach, expect, test } from "bun:test";
import { renderToString } from "react-dom/server";
import {
  chatEnvironmentPick,
  retryEnvironmentFor,
  useChatCloudEnvironment,
} from "../src/agent-session/acpmux/chatCloudEnvironment";
import {
  DEFAULT_IMAGE_KEY,
  defaultCloudImage,
  resetChatDisplayForTests,
  setChatDisplay,
} from "../src/agent-session/acpmux/chatDisplay";
import { AUTO_ENVIRONMENT, cloudStartEnvironment } from "../src/agent-session/acpmux/cloudEnvironmentChoice";

afterEach(() => {
  setChatDisplay({});
  resetChatDisplayForTests();
});

function NewChat({ chat }: { chat: string }) {
  const { pick } = useChatCloudEnvironment(chat);
  return <span data-environment={pick.current} />;
}

const drawnPick = (chat: string) => /data-environment="([^"]*)"/.exec(renderToString(<NewChat chat={chat} />))?.[1];

test("the key is cloud.defaultImage and is Auto until the host sends one", () => {
  expect(DEFAULT_IMAGE_KEY).toBe("cloud.defaultImage");
  expect(defaultCloudImage()).toBe(AUTO_ENVIRONMENT);
  setChatDisplay({ [DEFAULT_IMAGE_KEY]: "" });
  expect(defaultCloudImage()).toBe(AUTO_ENVIRONMENT);
  setChatDisplay({ [DEFAULT_IMAGE_KEY]: 7 });
  expect(defaultCloudImage()).toBe(AUTO_ENVIRONMENT);
});

test("a new chat's environment is the Default Image setting", () => {
  expect(drawnPick("chat-a")).toBe(AUTO_ENVIRONMENT);
  setChatDisplay({ [DEFAULT_IMAGE_KEY]: "env_000000000000000000000002" });
  expect(defaultCloudImage()).toBe("env_000000000000000000000002");
  expect(drawnPick("chat-b")).toBe("env_000000000000000000000002");
  // Its Cloud send names that environment; Auto names none.
  expect(cloudStartEnvironment(undefined, chatEnvironmentPick(undefined, defaultCloudImage()))).toBe(
    "env_000000000000000000000002",
  );
  expect(cloudStartEnvironment(undefined, chatEnvironmentPick(undefined, AUTO_ENVIRONMENT))).toBeUndefined();
});

test("a chat's own pick wins over the setting, and an empty setting is Auto", () => {
  expect(chatEnvironmentPick("env_own", "env_setting")).toBe("env_own");
  expect(chatEnvironmentPick(undefined, "env_setting")).toBe("env_setting");
  expect(chatEnvironmentPick(undefined, "")).toBe(AUTO_ENVIRONMENT);
  expect(chatEnvironmentPick(undefined, undefined)).toBe(AUTO_ENVIRONMENT);
  // A start that names its own environment still names it.
  expect(cloudStartEnvironment("env_start", "env_setting")).toBe("env_start");
});

// Review of https://github.com/manaflow-ai/cmux/pull/51769: the platform also makes `denv_` ids, which
// cmux-tui's start accepts (start_chat_cli.rs valid_environment); the chat page takes them too.
test("a denv_ environment id is a Default Image too; anything else reads as Auto", () => {
  setChatDisplay({ [DEFAULT_IMAGE_KEY]: "denv_000000000000000000000002" });
  expect(defaultCloudImage()).toBe("denv_000000000000000000000002");
  setChatDisplay({ [DEFAULT_IMAGE_KEY]: "xenv_000000000000000000000002" });
  expect(defaultCloudImage()).toBe(AUTO_ENVIRONMENT);
  setChatDisplay({ [DEFAULT_IMAGE_KEY]: "env_123" });
  expect(defaultCloudImage()).toBe(AUTO_ENVIRONMENT);
});

// CAPY-2 (cmux#47627): a failed start's Retry keeps its environment unless the chat picks another.
test("a failed start's retry keeps its environment until a deliberate pick, Auto included", () => {
  // No pick since the failed send (the pick reset after Send): Retry names the failed start's target.
  expect(retryEnvironmentFor(undefined, undefined, "env_gpu")).toBe("env_gpu");
  expect(cloudStartEnvironment(retryEnvironmentFor(undefined, undefined, "env_gpu"), AUTO_ENVIRONMENT)).toBe("env_gpu");
  // A deliberate pick replaces it, Auto included.
  expect(retryEnvironmentFor(undefined, "env_web", "env_gpu")).toBeUndefined();
  expect(retryEnvironmentFor(undefined, AUTO_ENVIRONMENT, "env_gpu")).toBeUndefined();
  // A changed prompt supplies no retry, so it never inherits the previous target.
  expect(retryEnvironmentFor(undefined, undefined, undefined)).toBeUndefined();
  // A start that names its own environment still names it.
  expect(retryEnvironmentFor("env_start", undefined, "env_gpu")).toBe("env_start");
});
