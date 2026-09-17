type MessageTree = Record<string, unknown>;

function isMessageTree(value: unknown): value is MessageTree {
  return value != null && typeof value === "object" && !Array.isArray(value);
}

/**
 * Namespaces only read by client components under their own route subtree.
 * That subtree mounts a nested provider with the full catalog; every other
 * page ships without them. `community` stays shared because the download
 * confirmation reads it outside the community route.
 */
export const SUBTREE_CLIENT_NAMESPACES = ["docs"] as const;

/**
 * The catalog every client component may read. Large bodies that only
 * server components render are dropped so they do not travel with each page.
 */
export function pruneClientMessages(messages: MessageTree): MessageTree {
  const pruned: MessageTree = { ...messages };
  const landing = isMessageTree(messages.landing)
    ? { ...messages.landing }
    : undefined;
  if (landing && isMessageTree(landing.compare)) {
    const compare = { ...landing.compare };
    delete compare.pages;
    landing.compare = compare;
    pruned.landing = landing;
  }

  const blog = isMessageTree(messages.blog) ? { ...messages.blog } : undefined;
  if (blog && isMessageTree(blog.posts)) {
    blog.posts = Object.fromEntries(
      Object.entries(blog.posts).map(([key, value]) => {
        if (!isMessageTree(value)) {
          return [key, value];
        }
        const { title, date, summary } = value;
        return [key, { title, date, summary }];
      }),
    );
    pruned.blog = blog;
  }

  return pruned;
}

/** The shared catalog without the subtree-only namespaces. */
export function sharedClientMessages(messages: MessageTree): MessageTree {
  const pruned = pruneClientMessages(messages);
  for (const namespace of SUBTREE_CLIENT_NAMESPACES) {
    delete pruned[namespace];
  }
  return pruned;
}
