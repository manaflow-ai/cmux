// The shape of a pull request a link card draws (pullRequestStore.ts reads it from the host). A leaf: a page
// that needs only the shape (pages/github) imports it here, not the store and the chip host behind it.
import type { HeaderPullRequest } from "../header/headerState";

/** One file of a pull request, for the card's by-kind breakdown of its `+/−`. */
export type PullRequestFile = {
  readonly path: string;
  readonly additions: number;
  readonly deletions: number;
};

/** The header's pull request with everything else the card draws. */
export type LinkedPullRequest = HeaderPullRequest & {
  readonly author?: string;
  /** The author's GitHub picture as a `data:image/…` URL (a cmux page's CSP allows only those);
   *  absent until the host has it, when the card draws the monogram in the same box. */
  readonly authorAvatar?: string;
  /** GitHub's colour for each label, six hex digits without `#`; a label missing here gets a tone
   *  picked from its name. */
  readonly labelColors?: Readonly<Record<string, string>>;
  /** GitHub's ISO 8601 text; empty when the host did not say. */
  readonly createdAt?: string;
  readonly updatedAt?: string;
  readonly mergedAt?: string;
  readonly additions?: number;
  readonly deletions?: number;
  /** Files changed as GitHub counts them, which can be more than `files` holds. */
  readonly changedFiles?: number;
  readonly files?: readonly PullRequestFile[];
  readonly labels?: readonly string[];
  readonly baseRef?: string;
  readonly headRef?: string;
  /** Its comments, review comments included; null or absent when the host's read did not say. */
  readonly comments?: number | null;
  /** `issue` for a GitHub issue (its `state` is `open`, `closed` or `not_planned`, and it has no
   *  checks, files or branches); absent for a pull request. */
  readonly kind?: "issue";
};
