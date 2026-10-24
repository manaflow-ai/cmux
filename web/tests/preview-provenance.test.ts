import { describe, expect, test } from "bun:test";

import {
  makePreviewPublication,
  PreviewPublicationInputError,
  previewExpired,
  previewMatchesCommit,
  publishPreviewPublication,
} from "../services/previews/provenance";

const COMMIT = "A".repeat(40);
const BASE = {
  repository: "manaflow-ai/cmux",
  branch: "feature/preview",
  commit: COMMIT,
  deploymentId: "dpl_123",
  url: "https://cmux-preview.example.dev/",
  createdAt: "2026-10-24T00:00:00.000Z",
  expiresAt: "2026-10-25T00:00:00.000Z",
} as const;

describe("preview publication provenance", () => {
  test("creates a stable public record with the full normalized SHA", () => {
    const publication = makePreviewPublication(BASE);
    expect(publication.commit).toBe(COMMIT.toLowerCase());
    expect(publication.status).toBe("ready");
    expect(publication.id).toMatch(/^preview_[0-9a-f]{24}$/u);
    expect(publication.key).toMatch(/^sha256:[0-9a-f]{64}$/u);
    expect(publication.url).toBe("https://cmux-preview.example.dev/");
    expect(previewMatchesCommit(publication, COMMIT)).toBe(true);
    expect(previewMatchesCommit(publication, "b".repeat(40))).toBe(false);
  });

  test("replays the same deployment and refuses URL or source changes", () => {
    const first = publishPreviewPublication(null, BASE);
    expect(first.kind).toBe("created");
    if (first.kind !== "created") return;
    expect(publishPreviewPublication(first.publication, BASE)).toEqual({ kind: "replayed", publication: first.publication });
    expect(publishPreviewPublication(first.publication, { ...BASE, url: "https://other.example.dev/" })).toEqual({ kind: "conflict", reason: "url_changed" });
    expect(publishPreviewPublication(first.publication, { ...BASE, commit: "b".repeat(40) })).toEqual({ kind: "conflict", reason: "source_changed" });
    expect(publishPreviewPublication(first.publication, { ...BASE, branch: "other-preview" })).toEqual({ kind: "conflict", reason: "source_changed" });
  });

  test("rejects abbreviated SHAs, private URLs, credentials, and bad expiry", () => {
    const invalid = [
      { ...BASE, commit: "abc1234" },
      { ...BASE, url: "http://preview.example.dev/" },
      { ...BASE, url: "https://user:pass@preview.example.dev/" },
      { ...BASE, url: "https://localhost:3000/" },
      { ...BASE, url: "https://169.254.169.254/" },
      { ...BASE, url: "https://[fd00::1]/" },
      { ...BASE, url: "https://preview.example.dev/?access_token=leak" },
      { ...BASE, expiresAt: "2026-10-23T00:00:00.000Z" },
    ];
    for (const input of invalid) expect(() => makePreviewPublication(input)).toThrow(PreviewPublicationInputError);
  });

  test("reports expiration from the record, with an injectable clock", () => {
    const publication = makePreviewPublication(BASE);
    expect(previewExpired(publication, "2026-10-24T23:59:59.000Z")).toBe(false);
    expect(previewExpired(publication, "2026-10-25T00:00:00.000Z")).toBe(true);
  });
});
