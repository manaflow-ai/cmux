import { intl } from "../../ui/intl";
export function attachmentPath(uri: string | undefined): string | undefined {
  if (!uri?.startsWith("file://")) return undefined;
  try {
    return decodeURIComponent(new URL(uri).pathname);
  } catch {
    return uri.slice(7);
  }
}

/// The size a file chip says: none for a link that names no size. A link to a file on the chat's
/// machine (attachments.ts `linkAttachment`, an image sent as the link to its original,
/// promptBudget.ts `originalLink`) has size 0 and no type until something reads it, and the sent
/// message drew that as "0 byte" beside a 92 KB screenshot (Leo, 2026-11-22: "what is this situation
/// with these attachments"). A file of known type keeps its size, 0 bytes included.
export function shownFileSize(file: { size?: number; mimeType?: string }): number | undefined {
  return file.size === undefined || (file.size === 0 && !file.mimeType) ? undefined : file.size;
}

export function fileSizeLabel(size: number | undefined, language: string): string | undefined {
  if (size === undefined || !Number.isFinite(size) || size < 0) return undefined;
  const units = ["byte", "kilobyte", "megabyte", "gigabyte", "terabyte", "petabyte"] as const;
  const exponent = Math.min(units.length - 1, Math.max(0, Math.floor(Math.log(size || 1) / Math.log(1024))));
  return intl
    .NumberFormat(language, {
      style: "unit",
      unit: units[exponent],
      unitDisplay: "short",
      maximumFractionDigits: 1,
    })
    .format(size / 1024 ** exponent);
}
