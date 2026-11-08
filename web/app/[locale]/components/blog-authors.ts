export type BlogAuthor = {
  name: string;
  handle: string;
  url: string;
  avatar: string;
};

export const lawrenceChen = {
  name: "Lawrence Chen",
  handle: "@lawrencecchen",
  url: "https://x.com/lawrencecchen",
  avatar: "/avatars/lawrencecchen.jpg",
} as const satisfies BlogAuthor;
