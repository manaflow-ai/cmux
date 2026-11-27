// l10n-allow-file: test fixture prompts and host words, not shipped UI.
// A page built again while its pane's Cloud start ran (cloudStartResume.ts): it shows that start and its end, never an
// empty New Tab with the prompt gone.
import { expect, test } from "bun:test";
import { cloudStartBegun, cloudStartPushed } from "./cloudStartProgress";
import { cloudStartEndPushed, readCloudStartResume, resumedCloudStart } from "./cloudStartResume";

const host = {
  key: "0b8d3a8e-6c1f-4b5e-9d55-0d6c2f1f2a11",
  task: "list the files",
  cwd: "/Users/dev/paint",
  harness: "claude",
  progress: { key: "0b8d3a8e-6c1f-4b5e-9d55-0d6c2f1f2a11", step: "opening", machine: "cloud-chats-7", size: "4 CPU" },
};

test("the handshake's record is read field by field; anything else is none", () => {
  expect(readCloudStartResume(host)).toEqual(host);
  expect(readCloudStartResume({ ...host, home: true, cwd: undefined })).toMatchObject({ home: true });
  expect(readCloudStartResume(undefined)).toBeUndefined();
  expect(readCloudStartResume({ task: "no key" })).toBeUndefined();
  expect(readCloudStartResume({ key: host.key })).toBeUndefined();
  expect(readCloudStartResume({ ...host, ended: { ok: false } })?.ended).toEqual({
    ok: false,
    code: "cloud_start_failed",
  });
});

test("a start still running shows its prompt and the step it is on, and it is marked as not this page's", () => {
  const shown = resumedCloudStart(undefined, readCloudStartResume(host)!, 50_000);
  expect(shown).toMatchObject({
    key: host.key,
    task: "list the files",
    state: "starting",
    folder: "paint",
    cwd: "/Users/dev/paint",
    step: "opening",
    machine: "cloud-chats-7",
    resumed: true,
  });
});

test("a start that failed before the page was built shows its failure, with the host's words and Retry", () => {
  const resume = readCloudStartResume({
    ...host,
    ended: {
      ok: false,
      code: "cloud_start_failed",
      message: "Couldn't copy the folder to cloud-chats-7.",
      retryable: true,
    },
  })!;
  expect(resumedCloudStart(undefined, resume)).toMatchObject({
    state: "failed",
    task: "list the files",
    message: "Couldn't copy the folder to cloud-chats-7.",
    retryable: true,
    resumed: true,
  });
});

test("a start that opened its chat shows nothing, and a page that already shows a start keeps it", () => {
  expect(resumedCloudStart(undefined, readCloudStartResume({ ...host, ended: { ok: true } })!)).toBeUndefined();
  const own = cloudStartBegun("another", "my own", undefined);
  expect(resumedCloudStart(own, readCloudStartResume(host)!)).toBe(own);
});

test("the host's end push ends a resumed start, and only a resumed one", () => {
  const resumed = resumedCloudStart(undefined, readCloudStartResume(host)!)!;
  const push = { key: host.key, ended: { ok: false, code: "cloud_start_failed", message: "Claude didn't start." } };
  const ended = cloudStartEndPushed(resumed, push);
  expect(ended.ended).toEqual({ ok: false, code: "cloud_start_failed", message: "Claude didn't start." });
  expect(ended.next).toMatchObject({ state: "failed", message: "Claude didn't start.", resumed: true });
  // The page that sent the start ends it with its own answer: the push leaves it alone.
  const own = cloudStartBegun(host.key, "list the files", undefined);
  expect(cloudStartEndPushed(own, push)).toEqual({ next: own });
  // Another start's end, or a push that is no end, changes nothing.
  expect(cloudStartEndPushed(resumed, { ...push, key: "other" })).toEqual({ next: resumed });
  expect(cloudStartEndPushed(resumed, { key: host.key, step: "opening" })).toEqual({ next: resumed });
  // An opened chat ends the card.
  expect(cloudStartEndPushed(resumed, { key: host.key, ended: { ok: true } }).next).toBeUndefined();
});

test("an ordinary progress push still moves a resumed start", () => {
  const resumed = resumedCloudStart(undefined, readCloudStartResume({ ...host, progress: undefined })!)!;
  expect(cloudStartPushed(resumed, { key: host.key, step: "folder" })).toMatchObject({ step: "folder", resumed: true });
});
