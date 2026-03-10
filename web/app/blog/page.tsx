import type { Metadata } from "next";
import Link from "next/link";
import { blogPosts } from "../components/blog-posts";

export const metadata: Metadata = {
  title: "Blog",
  description: "News and updates from the cmux team",
};

export default function BlogPage() {
  return (
    <>
      <h1>Blog</h1>
      <div className="space-y-4 mt-6">
        {blogPosts.map((post) => (
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
