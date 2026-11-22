// l10n-allow-file: gallery and test fixtures (sample thread titles, spaces and queries), not shipped UI.
// cmux-forum post, reply and search calls as each harness records them, for ForumCallCard's gallery
// and forumCalls.test.ts. The result text is the server's contract (cmux-tui acpmux forum_mcp.rs).
import { tool } from "../../../gallery/fixtures/acpmux";

const URL = "https://forum.example.com/t/acme";

/// An MCP result whose one text block is `value` as JSON.
export const mcpResult = (value: unknown) =>
  JSON.stringify({ content: [{ type: "text", text: JSON.stringify(value) }] });

export const POST_ARGS = {
  space: "fleet",
  kind: "finding",
  title: "Compile pool drains in 40 s when a lane pushes twice",
  body: "Two pushes inside a minute queue two compile checks; the second cancels nothing and the pool waits on both.\nRepro: push, amend, push again within 60 s.",
};

export const postCall = (status = "completed") =>
  tool("mcp__cmux-forum__post", "other", status, {
    inputSummary: JSON.stringify(POST_ARGS),
    ...(status === "completed" && {
      output: mcpResult({
        forum: "post",
        thread: {
          number: 214,
          title: POST_ARGS.title,
          space: "fleet",
          state: "open",
          comments: 0,
          url: `${URL}/fleet/214`,
        },
      }),
    }),
  });

export const replyCall = (status = "completed") =>
  tool("mcp__cmux-forum__reply", "other", status, {
    inputSummary: JSON.stringify({
      thread: 198,
      body: "Same here on the arm runners: the cache key misses when the lockfile only reorders.",
    }),
    ...(status === "completed" && {
      output: mcpResult({
        forum: "reply",
        thread: {
          number: 198,
          title: "Cargo cache misses after a lockfile reorder",
          space: "general",
          state: "answered",
          comments: 4,
          url: `${URL}/general/198`,
        },
        comment: { id: 911 },
      }),
    }),
  });

const HITS = [
  {
    number: 198,
    title: "Cargo cache misses after a lockfile reorder",
    space: "general",
    state: "answered",
    comments: 4,
    snippet: "The cache key hashes the lockfile bytes, so a reorder with no version change misses.",
  },
  {
    number: 176,
    title: "How we key the sccache bucket per toolchain",
    space: "fleet",
    state: "open",
    comments: 2,
    snippet: "One bucket per rustc version and target; the lockfile hash only picks the prefix.",
  },
  {
    number: 151,
    title: "Build cache: what is shared between lanes",
    space: "fleet",
    state: "closed",
    comments: 7,
    snippet: "Lanes share the registry and git caches; target dirs never.",
  },
];

export const searchCall = (status = "completed", hits = HITS) =>
  tool("mcp__cmux-forum__search", "other", status, {
    inputSummary: JSON.stringify({ query: "cargo cache" }),
    ...(status === "completed" && { output: mcpResult({ forum: "search", query: "cargo cache", hits }) }),
  });

/// Codex's shape: the call nests the server and tool under its input.
export const codexPostCall = () =>
  tool("cmux-forum.post", "other", "completed", {
    inputSummary: JSON.stringify({ server: "cmux-forum", tool: "post", arguments: POST_ARGS }),
    output: mcpResult({
      forum: "post",
      thread: {
        number: 215,
        title: POST_ARGS.title,
        space: "fleet",
        state: "open",
        comments: 0,
        url: `${URL}/fleet/215`,
      },
    }),
  });

export const unconfiguredCall = () =>
  tool("mcp__cmux-forum__post", "other", "failed", {
    inputSummary: JSON.stringify(POST_ARGS),
    output: JSON.stringify({
      content: [
        {
          type: "text",
          text: "The hosted forum is not set up on this machine (set CMUX_FORUM_TEAM and CMUX_FORUM_KEY).",
        },
      ],
      isError: true,
    }),
  });
