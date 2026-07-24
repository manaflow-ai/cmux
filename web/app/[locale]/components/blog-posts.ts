import {
  englishFallbackContentLocales,
  fallbackContentLocales,
} from "@/i18n/locale-availability";
import { lawrenceChen, type BlogAuthor } from "./blog-authors";

export type BlogPost = {
  slug: string;
  key: string;
  title: string;
  date: string;
  summary: string;
  author: BlogAuthor;
  locales?: readonly string[];
};

export const blogPosts = [
  {
    slug: "claude-code-best-worktree-manager",
    key: "claudeCodeBestWorktreeManager",
    title: "Superrepos and Why Claude Code Is the Best Worktree Manager",
    date: "2026-07-23",
    summary:
      "A lot of people have asked why cmux doesn't have a worktree manager yet. The best manager can choose a worktree, second checkout, sandbox, VM, or GPU cluster.",
    author: lawrenceChen,
  },
  {
    slug: "cmux-fork",
    key: "cmuxFork",
    title: "Introducing cmux Fork",
    date: "2026-07-14",
    summary:
      "Branch an agent conversation into a new split, tab, or workspace without losing its context.",
    author: lawrenceChen,
  },
  {
    slug: "cmux-home",
    key: "cmuxHome",
    title: "cmux home",
    date: "2026-06-23",
    summary:
      "We're not adding worktrees to cmux. It's a primitive, so you can script your own worktrees, multiple checkouts, or remote dev and make it feel like home.",
    author: lawrenceChen,
  },
  {
    slug: "cmux-history",
    key: "cmuxHistory",
    title: "cmux history",
    date: "2026-06-02",
    summary:
      "Reopen closed terminals, browsers, workspaces, and agent sessions with Cmd+Shift+T, and retrace your focus with Cmd+[ and Cmd+].",
    author: lawrenceChen,
  },
  {
    slug: "cmux-finder",
    key: "cmuxFinder",
    title: "Introducing cmux Finder",
    date: "2026-05-22",
    summary:
      "cmux now has a file explorer that previews videos, images, PDFs, and markdown files.",
    author: lawrenceChen,
  },
  {
    slug: "cmux-vault",
    key: "cmuxVault",
    title: "cmux Vault",
    date: "2026-05-22",
    summary:
      "Search Codex, Claude Code, OpenCode, and Pi sessions from the Vault pane and drag them into your workspace.",
    author: lawrenceChen,
  },
  {
    slug: "passkey-auth",
    key: "passkeyAuth",
    title: "Passkey auth in the cmux browser",
    date: "2026-05-22",
    summary:
      "cmux's embedded browser supports passkey authentication and can import cookies from other browsers with cmux browser import.",
    author: lawrenceChen,
  },
  {
    slug: "task-manager",
    key: "taskManager",
    title: "Task Manager in cmux",
    date: "2026-05-22",
    summary:
      "Use cmux top or Task Manager from the command palette to see CPU and RAM usage for your coding agents.",
    author: lawrenceChen,
  },
  {
    slug: "markdown-viewer",
    key: "markdownViewer",
    title: "A better markdown viewer in cmux",
    date: "2026-05-22",
    summary:
      "Open README.md with cmux open or drag markdown files from the right sidebar.",
    author: lawrenceChen,
  },
  {
    slug: "unread-shortcuts",
    key: "unreadShortcuts",
    title: "Unread workspace shortcuts in cmux",
    date: "2026-05-22",
    summary:
      "Cmd+Control+U cycles through unread workspaces while keeping them unread, and Cmd+Option+U toggles read state.",
    author: lawrenceChen,
  },
  {
    slug: "session-restore",
    key: "sessionRestore",
    title: "Session restore in cmux",
    date: "2026-05-13",
    summary:
      "cmux restores layout, scrollback, browser history, and supported agent sessions when hooks have captured a resume token.",
    author: lawrenceChen,
  },
  {
    slug: "cmux-ssh",
    key: "cmuxSsh",
    title: "cmux SSH",
    date: "2026-03-30",
    summary:
      "One command gives you persistent remote sessions, browser panes that reach remote ports, and agent notifications that come home.",
    author: lawrenceChen,
    locales: fallbackContentLocales,
  },
  {
    slug: "cmux-claude-teams",
    key: "cmuxClaudeTeams",
    title: "Claude Code teammate agents as native cmux panes",
    date: "2026-03-30",
    summary:
      "Claude Code's teammate mode requires tmux. cmux fakes it so teammates become native splits with sidebar metadata and notifications.",
    author: lawrenceChen,
    locales: englishFallbackContentLocales,
  },
  {
    slug: "cmux-omo",
    key: "cmuxOmo",
    title: "oh-my-openagent subagents as native cmux panes",
    date: "2026-03-30",
    summary:
      "oh-my-openagent (formerly oh-my-opencode) orchestrates parallel specialist agents across Claude, GPT, and Gemini. cmux omo turns their tmux panes into native splits.",
    author: lawrenceChen,
    locales: englishFallbackContentLocales,
  },
  {
    slug: "gpl",
    key: "gpl",
    title: "cmux is now GPL",
    date: "2026-03-30",
    summary:
      "cmux relicensed from AGPL-3.0 to GPL-3.0.",
    author: lawrenceChen,
    locales: englishFallbackContentLocales,
  },
  {
    slug: "cmd-shift-u",
    key: "cmdShiftU",
    title: "Cmd+Shift+U",
    date: "2026-03-04",
    summary:
      "How Cmd+Shift+U navigates between finished agents across workspaces in cmux.",
    author: lawrenceChen,
  },
  {
    slug: "zen-of-cmux",
    key: "zenOfCmux",
    title: "The Zen of cmux",
    date: "2026-02-27",
    summary:
      "cmux is a primitive, not a solution. It gives you composable pieces and your workflow is up to you.",
    author: lawrenceChen,
  },
  {
    slug: "show-hn-launch",
    key: "showHnLaunch",
    title: "Launching cmux on Show HN",
    date: "2026-02-21",
    summary:
      "cmux hit #2 on Hacker News, got shared by Mitchell Hashimoto, and went viral in Japan.",
    author: lawrenceChen,
  },
  {
    slug: "introducing-cmux",
    key: "introducingCmux",
    title: "Introducing cmux",
    date: "2026-02-12",
    summary:
      "A native macOS terminal built on Ghostty, designed for running multiple AI coding agents side by side.",
    author: lawrenceChen,
  },
] satisfies readonly BlogPost[];

export function blogPostsForLocale(locale: string) {
  return blogPosts.filter(
    (post) => !post.locales || post.locales.some((candidate) => candidate === locale),
  );
}
