const maxImageAttachmentCount = 10;
const maxImageAttachmentBytes = 4 * 1024 * 1024;
const maxDiagnosticsAttachmentCount = 1;
const maxDiagnosticsAttachmentBytes = 512 * 1024;
// Keep multipart requests below Vercel Functions' 4.5 MB request-body limit.
const maxTotalAttachmentBytes = 4 * 1024 * 1024;
const allowedImageTypes = new Set([
  "image/gif",
  "image/heic",
  "image/heif",
  "image/jpeg",
  "image/png",
  "image/tiff",
  "image/webp",
]);
const allowedDiagnosticsTypes = new Set(["text/plain"]);

export type FeedbackAttachmentErrorCode =
  | "ERROR_DIAGNOSTICS_ATTACHMENT_TOO_LARGE"
  | "ERROR_IMAGE_ATTACHMENT_TOO_LARGE"
  | "ERROR_INVALID_DIAGNOSTICS_ATTACHMENT"
  | "ERROR_INVALID_IMAGE_ATTACHMENT"
  | "ERROR_TOO_MANY_DIAGNOSTICS"
  | "ERROR_TOO_MANY_IMAGES"
  | "ERROR_TOTAL_ATTACHMENTS_TOO_LARGE"
  | "ERROR_UNSUPPORTED_DIAGNOSTICS_TYPE"
  | "ERROR_UNSUPPORTED_IMAGE_TYPE";

export type FeedbackAttachmentError = {
  code: FeedbackAttachmentErrorCode;
  status: 400 | 413 | 415;
};

export type PreparedFeedbackAttachment = {
  content: Buffer;
  contentType: string;
  filename: string;
  kind: "diagnostics" | "image";
  size: number;
};

export type PrepareFeedbackAttachmentsResult =
  | { attachments: PreparedFeedbackAttachment[] }
  | { error: FeedbackAttachmentError };

export async function prepareFeedbackAttachments(
  imageValues: FormDataEntryValue[],
  diagnosticsValues: FormDataEntryValue[] = [],
): Promise<PrepareFeedbackAttachmentsResult> {
  if (imageValues.some((value) => !isNamedFile(value))) {
    return error("ERROR_INVALID_IMAGE_ATTACHMENT", 400);
  }

  if (diagnosticsValues.some((value) => !isNamedFile(value))) {
    return error("ERROR_INVALID_DIAGNOSTICS_ATTACHMENT", 400);
  }

  const imageFiles = imageValues.filter(isNamedFile);
  const diagnosticsFiles = diagnosticsValues.filter(isNamedFile);

  if (imageFiles.length > maxImageAttachmentCount) {
    return error("ERROR_TOO_MANY_IMAGES", 400);
  }

  if (diagnosticsFiles.length > maxDiagnosticsAttachmentCount) {
    return error("ERROR_TOO_MANY_DIAGNOSTICS", 400);
  }

  let totalSize = 0;
  const attachments: PreparedFeedbackAttachment[] = [];

  for (const file of diagnosticsFiles) {
    const diagnosticsContentType = file.type.split(";")[0]?.trim() ?? "";
    if (!allowedDiagnosticsTypes.has(diagnosticsContentType)) {
      return error("ERROR_UNSUPPORTED_DIAGNOSTICS_TYPE", 415);
    }

    if (file.size > maxDiagnosticsAttachmentBytes) {
      return error("ERROR_DIAGNOSTICS_ATTACHMENT_TOO_LARGE", 413);
    }

    totalSize += file.size;
    if (totalSize > maxTotalAttachmentBytes) {
      return error("ERROR_TOTAL_ATTACHMENTS_TOO_LARGE", 413);
    }

    attachments.push({
      content: Buffer.from(await file.arrayBuffer()),
      contentType: diagnosticsContentType,
      filename: sanitizeFeedbackFilename(file.name),
      kind: "diagnostics",
      size: file.size,
    });
  }

  for (const file of imageFiles) {
    if (!allowedImageTypes.has(file.type)) {
      return error("ERROR_UNSUPPORTED_IMAGE_TYPE", 415);
    }

    if (file.size > maxImageAttachmentBytes) {
      return error("ERROR_IMAGE_ATTACHMENT_TOO_LARGE", 413);
    }

    totalSize += file.size;
    if (totalSize > maxTotalAttachmentBytes) {
      return error("ERROR_TOTAL_ATTACHMENTS_TOO_LARGE", 413);
    }

    attachments.push({
      content: Buffer.from(await file.arrayBuffer()),
      contentType: file.type,
      filename: sanitizeFeedbackFilename(file.name),
      kind: "image",
      size: file.size,
    });
  }

  return { attachments };
}

function isNamedFile(value: FormDataEntryValue): value is File {
  return value instanceof File && value.name.trim().length > 0;
}

function sanitizeFeedbackFilename(fileName: string) {
  const cleaned = fileName.replace(/[\r\n"]/g, "").trim();
  return cleaned.length > 0 ? cleaned : "attachment";
}

function error(
  code: FeedbackAttachmentErrorCode,
  status: FeedbackAttachmentError["status"],
): PrepareFeedbackAttachmentsResult {
  return { error: { code, status } };
}
