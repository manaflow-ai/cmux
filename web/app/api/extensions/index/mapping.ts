import { z } from "zod";

export const githubRepositorySchema = z.object({
  full_name: z.string().min(1),
  owner: z.object({
    login: z.string().min(1),
    avatar_url: z.url(),
  }).passthrough(),
  description: z.string().nullable(),
  stargazers_count: z.number().int().nonnegative(),
  language: z.string().nullable(),
  pushed_at: z.iso.datetime(),
  created_at: z.iso.datetime(),
  html_url: z.url(),
  fork: z.boolean(),
  archived: z.boolean(),
}).passthrough();

const registryRepoSchema = z.string().regex(/^[A-Za-z0-9-]+\/[A-Za-z0-9._-]+$/);
const isoDateSchema = z.string().regex(/^\d{4}-\d{2}-\d{2}$/);

export const extensionsRegistrySchema = z.object({
  $comment: z.string().optional(),
  extensions: z.array(z.object({
    repo: registryRepoSchema,
    addedAt: isoDateSchema,
  }).strict()),
}).strict();

export const extensionDtoSchema = z.object({
  fullName: z.string().min(1),
  owner: z.string().min(1),
  ownerAvatarUrl: z.url(),
  description: z.string().nullable(),
  stars: z.number().int().nonnegative(),
  language: z.string().nullable(),
  pushedAt: z.iso.datetime(),
  createdAt: z.iso.datetime(),
  url: z.url(),
  supported: z.boolean(),
}).strict();

export const extensionsIndexResponseSchema = z.object({
  extensions: z.array(extensionDtoSchema),
  fetchedAt: z.iso.datetime(),
}).strict();

export type GitHubRepository = z.infer<typeof githubRepositorySchema>;
export type ExtensionsRegistry = z.infer<typeof extensionsRegistrySchema>;
export type ExtensionDto = z.infer<typeof extensionDtoSchema>;
export type ExtensionsIndexResponse = z.infer<typeof extensionsIndexResponseSchema>;

export function mapGithubRepositoriesToExtensions(
  repositories: readonly GitHubRepository[],
): ExtensionDto[] {
  const mapped = repositories
    .filter((repo) => !repo.fork && !repo.archived)
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
      supported: true,
    }));

  return z.array(extensionDtoSchema).parse(mapped);
}
