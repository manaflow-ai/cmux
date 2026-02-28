import type { Metadata } from "next";
import Link from "next/link";

export const metadata: Metadata = {
  title: "The Zen of cmux",
  description:
    "cmux is a primitive, not a solution. It gives you composable pieces and your workflow is up to you.",
  keywords: [
    "cmux",
    "terminal",
    "macOS",
    "CLI",
    "composable",
    "developer tools",
    "AI coding agents",
    "workflow",
  ],
  openGraph: {
    title: "The Zen of cmux",
    description:
      "cmux is a primitive, not a solution. It gives you composable pieces and your workflow is up to you.",
    type: "article",
    publishedTime: "2026-02-27T00:00:00Z",
    url: "https://cmux.dev/blog/zen-of-cmux",
  },
  twitter: {
    card: "summary",
    title: "The Zen of cmux",
    description:
      "cmux is a primitive, not a solution. It gives you composable pieces and your workflow is up to you.",
  },
  alternates: {
    canonical: "https://cmux.dev/blog/zen-of-cmux",
  },
};

export default function ZenOfCmuxPage() {
  return (
    <>
      <div className="mb-8">
        <Link
          href="/blog"
          className="text-sm text-muted hover:text-foreground transition-colors"
        >
          &larr; Back to blog
        </Link>
      </div>

      <h1>The Zen of cmux</h1>
      <time dateTime="2026-02-27" className="text-sm text-muted">
        February 27, 2026
      </time>

      <p className="mt-6">
        cmux is not prescriptive about how developers hold their tools.
        It&apos;s a terminal and browser with a CLI, and the rest is up to you.
      </p>

      <p>
        cmux is a primitive, not a solution. It gives you a terminal, a browser,
        notifications, workspaces, splits, tabs, and a CLI to control all of
        it. cmux doesn&apos;t force you into an opinionated
        way to use coding agents. What you build with the primitives is yours.
      </p>

      <p>
        The best developers have always built their own tools. Nobody has figured
        out the best way to work with agents yet, and the teams building closed
        products definitely haven&apos;t either. The developers closest to their
        own codebases will figure it out first.
      </p>

      <p>
        Give a million developers composable primitives and they&apos;ll
        collectively find the most efficient workflows faster than any product
        team could design top-down.
      </p>
    </>
  );
}
