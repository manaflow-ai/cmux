import { z } from "zod";

export const githubSearchRepositorySchema = z.object({
  full_name: z.string().min(1),
  owner: z.object({
    login: z.string().min(1),
    avatar_url: z.string().url(),
  }).passthrough(),
  description: z.string().nullable(),
  stargazers_count: z.number().int().nonnegative(),
  language: z.string().nullable(),
  pushed_at: z.string().datetime(),
  created_at: z.string().datetime(),
  html_url: z.string().url(),
  fork: z.boolean(),
  archived: z.boolean(),
}).passthrough();

export const githubSearchResponseSchema = z.object({
  items: z.array(githubSearchRepositorySchema),
}).passthrough();

export const extensionsBlocklistSchema = z.object({
  $comment: z.string().optional(),
  blocked: z.array(z.string()),
}).strict();

export const extensionDtoSchema = z.object({
  fullName: z.string().min(1),
  owner: z.string().min(1),
  ownerAvatarUrl: z.string().url(),
  description: z.string().nullable(),
  stars: z.number().int().nonnegative(),
  language: z.string().nullable(),
  pushedAt: z.string().datetime(),
  createdAt: z.string().datetime(),
  url: z.string().url(),
}).strict();

export const extensionsIndexResponseSchema = z.object({
  extensions: z.array(extensionDtoSchema),
  fetchedAt: z.string().datetime(),
}).strict();

export type GitHubSearchRepository = z.infer<typeof githubSearchRepositorySchema>;
export type ExtensionDto = z.infer<typeof extensionDtoSchema>;
export type ExtensionsIndexResponse = z.infer<typeof extensionsIndexResponseSchema>;

export function mapGithubRepositoriesToExtensions(
  repositories: readonly GitHubSearchRepository[],
  blocklistedFullNames: readonly string[],
): ExtensionDto[] {
  const blocked = new Set(blocklistedFullNames.map((name) => name.toLowerCase()));
  const mapped = repositories
    .filter((repo) => !repo.fork && !repo.archived)
    .filter((repo) => !blocked.has(repo.full_name.toLowerCase()))
    .map((repo) => ({
      fullName: repo.full_name,
      owner: repo.owner.login,
      ownerAvatarUrl: repo.owner.avatar_url,
      description: repo.description,
      stars: repo.stargazers_count,
      language: repo.language,
      pushedAt: repo.pushed_at,
      createdAt: repo.created_at,
      url: repo.html_url,
    }));

  return z.array(extensionDtoSchema).parse(mapped);
}
