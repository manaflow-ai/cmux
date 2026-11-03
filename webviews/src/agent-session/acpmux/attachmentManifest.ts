/** Keep the complete resource link: its metadata authenticates a manifest in its own session. */
export type UploadManifest = Record<string, unknown> & { type: "resource_link"; uri: string };
export type ManifestAttachment = {
  blockIndex: number;
  block: UploadManifest;
  displayPart?: Record<string, unknown>;
};
export type AttachmentManifestPage = {
  attachments: ManifestAttachment[];
  hasMore: boolean;
  manifestOffset: number;
};
export type AttachmentManifestReader = (
  sessionId: string,
  manifest: UploadManifest,
  offset: number,
) => Promise<AttachmentManifestPage>;

export function uploadManifest(value: unknown): UploadManifest | undefined {
  if (!value || typeof value !== "object" || Array.isArray(value)) return undefined;
  const block = value as Record<string, unknown>;
  return block.type === "resource_link" && typeof block.uri === "string" ? (block as UploadManifest) : undefined;
}

/** A malformed page is an error, never a partially displayed attachment list. */
export function attachmentManifestPage(value: unknown, offset: number): AttachmentManifestPage {
  const page = value as Partial<AttachmentManifestPage> | undefined;
  if (
    !page ||
    !Array.isArray(page.attachments) ||
    typeof page.hasMore !== "boolean" ||
    !Number.isSafeInteger(page.manifestOffset) ||
    Number(page.manifestOffset) < offset ||
    (page.hasMore && (Number(page.manifestOffset) <= offset || page.attachments.length === 0)) ||
    page.attachments.some(
      (entry) =>
        !entry || !Number.isSafeInteger(entry.blockIndex) || entry.blockIndex < 0 || !uploadManifest(entry.block),
    )
  )
    throw new Error("Invalid attachment manifest page");
  return page as AttachmentManifestPage;
}
