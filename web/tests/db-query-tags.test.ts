import { afterEach, describe, expect, test } from "bun:test";
import {
  currentCloudDbQueryTags,
  formatCloudDbQueryComment,
  runWithCloudDbQueryTags,
  tagCloudDbQuery,
} from "../db/queryTags";

const savedEnv = { ...process.env };

afterEach(() => {
  process.env = { ...savedEnv };
});

describe("cloud db query tags", () => {
  test("renders bounded SQLCommenter keys in sorted order with encoded values", () => {
    const comment = formatCloudDbQueryComment(
      { source: "app", route: "/api/devices/iroh/register" },
      "abcdef123456",
    );
    expect(comment).toBe(
      "/*application='cmux-web',release='abcdef123456',route='%2Fapi%2Fdevices%2Firoh%2Fregister',source='app'*/",
    );
  });

  test("escapes quotes and comment terminators so a value cannot end the comment", () => {
    const comment = formatCloudDbQueryComment({ source: "app", job: "x'*/; drop" }, undefined);
    expect(comment).not.toContain("*/;");
    expect(comment).toBe("/*application='cmux-web',job='x%27*%2F%3B%20drop',source='app'*/");
  });

  test("appends the comment to a statement once and leaves tagged statements alone", () => {
    delete process.env.VERCEL_GIT_COMMIT_SHA;
    const tagged = runWithCloudDbQueryTags({ source: "app", route: "/api/vm" }, () =>
      tagCloudDbQuery("select 1 \n"),
    );
    expect(tagged).toBe("select 1 /*application='cmux-web',route='%2Fapi%2Fvm',source='app'*/");
    expect(tagCloudDbQuery(tagged)).toBe(tagged);
  });

  test("scripts and crons identify themselves through the environment when no context is set", () => {
    process.env.CMUX_DB_QUERY_SOURCE = "script";
    process.env.CMUX_DB_QUERY_JOB = "stripe-backfill";
    expect(currentCloudDbQueryTags()).toEqual({ source: "script", job: "stripe-backfill" });
    // An explicit context still wins.
    expect(runWithCloudDbQueryTags({ source: "app", route: "/x" }, () => currentCloudDbQueryTags()))
      .toEqual({ source: "app", route: "/x" });
  });

  test("defaults to the application and source when nothing else is known", () => {
    delete process.env.VERCEL_GIT_COMMIT_SHA;
    delete process.env.CMUX_DB_QUERY_SOURCE;
    delete process.env.CMUX_DB_QUERY_JOB;
    expect(formatCloudDbQueryComment(undefined, undefined)).toBe("/*application='cmux-web',source='app'*/");
  });
});
