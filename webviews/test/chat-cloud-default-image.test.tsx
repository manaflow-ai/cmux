// Settings > Cloud > Default Image (`cloud.defaultImage`, PR https://github.com/manaflow-ai/cmux/pull/51769):
// the composer no longer picks a Cloud environment, so a new Cloud chat starts from the setting. The
// host sends the key with the chat's display keys (Swift AgentPaneDisplaySetting.followedAppPaths);
// useChatCloudEnvironment holds it as the chat's pick until the chat picks its own.
import { afterEach, expect, test } from "bun:test";
import { renderToString } from "react-dom/server";
import { chatEnvironmentPick, useChatCloudEnvironment } from "../src/agent-session/acpmux/chatCloudEnvironment";
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
  setChatDisplay({ [DEFAULT_IMAGE_KEY]: "env_00000000000000000002" });
  expect(defaultCloudImage()).toBe("env_00000000000000000002");
  expect(drawnPick("chat-b")).toBe("env_00000000000000000002");
  // Its Cloud send names that environment; Auto names none.
  expect(cloudStartEnvironment(undefined, chatEnvironmentPick(undefined, defaultCloudImage()))).toBe(
    "env_00000000000000000002",
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
