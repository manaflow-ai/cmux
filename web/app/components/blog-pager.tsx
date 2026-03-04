"use client";

import Link from "next/link";
import { usePathname } from "next/navigation";
import { blogPosts } from "./blog-posts";

export function BlogPager() {
  const pathname = usePathname();
  const index = blogPosts.findIndex(
    (post) => `/blog/${post.slug}` === pathname
  );
  const prev = index > 0 ? blogPosts[index - 1] : null;
  const next = index < blogPosts.length - 1 ? blogPosts[index + 1] : null;

  if (!prev && !next) return null;

  return (
    <nav className="flex items-center justify-between mt-12 pt-6 border-t border-border text-[14px]">
      {prev ? (
        <Link
          href={`/blog/${prev.slug}`}
          className="flex items-center gap-1.5 text-muted hover:text-foreground transition-colors"
        >
          <span aria-hidden>&larr;</span>
          {prev.title}
        </Link>
      ) : (
        <span />
      )}
      {next ? (
        <Link
          href={`/blog/${next.slug}`}
          className="flex items-center gap-1.5 text-muted hover:text-foreground transition-colors"
        >
          {next.title}
          <span aria-hidden>&rarr;</span>
        </Link>
      ) : (
        <span />
      )}
    </nav>
  );
}
