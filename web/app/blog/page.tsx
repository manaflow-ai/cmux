import type { Metadata } from "next";
import Link from "next/link";

export const metadata: Metadata = {
  title: "Blog",
  description: "News and updates from the cmux team",
};

const posts = [
  {
    slug: "show-hn-launch",
    title: "Launching cmux on Show HN",
    date: "2026-02-21",
    summary:
      "cmux hit #2 on Hacker News, got shared by Mitchell Hashimoto, and went viral in Japan.",
  },
  {
    slug: "introducing-cmux",
    title: "Introducing cmux",
    date: "2026-02-12",
    summary:
      "A native macOS terminal built on Ghostty, designed for running multiple AI coding agents side by side.",
  },
];

export default function BlogPage() {
  return (
    <>
      <h1>Blog</h1>
      <div className="space-y-8 mt-6">
        {posts.map((post) => (
          <article key={post.slug}>
            <Link
              href={`/blog/${post.slug}`}
              className="block group"
            >
              <h2 className="text-lg font-medium group-hover:underline">
                {post.title}
              </h2>
              <time className="text-sm text-muted">{post.date}</time>
              <p className="mt-1 text-muted">{post.summary}</p>
            </Link>
          </article>
        ))}
      </div>
    </>
  );
}
