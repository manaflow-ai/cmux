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

export type PreparedFeedbackAttachment = {
  content: Buffer;
  contentType: string;
  filename: string;
  kind: "diagnostics" | "image";
  size: number;
};

export type PrepareFeedbackAttachmentsResult =
  | { attachments: PreparedFeedbackAttachment[] }
  | { errorResponse: Response };

export async function prepareFeedbackAttachments(
  imageValues: FormDataEntryValue[],
  diagnosticsValues: FormDataEntryValue[] = [],
): Promise<PrepareFeedbackAttachmentsResult> {
  const imageFiles = imageValues.filter(
    (value): value is File => value instanceof File && value.name.length > 0,
  );
  const diagnosticsFiles = diagnosticsValues.filter(
    (value): value is File => value instanceof File && value.name.length > 0,
  );

  if (imageFiles.length > maxImageAttachmentCount) {
    return {
      errorResponse: jsonError("Too many images attached", 400),
    };
  }

  if (diagnosticsFiles.length > maxDiagnosticsAttachmentCount) {
    return {
      errorResponse: jsonError("Too many diagnostics attachments", 400),
    };
  }

  let totalSize = 0;
  const attachments: PreparedFeedbackAttachment[] = [];

  for (const file of diagnosticsFiles) {
    const diagnosticsContentType = file.type.split(";")[0]?.trim() ?? "";
    if (!allowedDiagnosticsTypes.has(diagnosticsContentType)) {
      return {
        errorResponse: jsonError("Unsupported diagnostics attachment type", 415),
      };
    }

    if (file.size > maxDiagnosticsAttachmentBytes) {
      return {
        errorResponse: jsonError("Diagnostics attachment is too large", 413),
      };
    }

    totalSize += file.size;
    if (totalSize > maxTotalAttachmentBytes) {
      return {
        errorResponse: jsonError("Total attachment size is too large", 413),
      };
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
      return {
        errorResponse: jsonError("Unsupported image attachment type", 415),
      };
    }

    if (file.size > maxImageAttachmentBytes) {
      return {
        errorResponse: jsonError("Image attachment is too large", 413),
      };
    }

    totalSize += file.size;
    if (totalSize > maxTotalAttachmentBytes) {
      return {
        errorResponse: jsonError("Total attachment size is too large", 413),
      };
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

function sanitizeFeedbackFilename(fileName: string) {
  const cleaned = fileName.replace(/[\r\n"]/g, "").trim();
  return cleaned.length > 0 ? cleaned : "attachment";
}

function jsonError(message: string, status: number) {
  return Response.json(
    { error: message },
    {
      status,
      headers: {
        "Cache-Control": "no-store",
      },
    },
  );
}
