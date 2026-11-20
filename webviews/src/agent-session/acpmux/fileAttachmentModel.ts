export function attachmentPath(uri: string | undefined): string | undefined {
  if (!uri?.startsWith("file://")) return undefined;
  try {
    return decodeURIComponent(new URL(uri).pathname);
  } catch {
    return uri.slice(7);
  }
}

export function fileSizeLabel(size: number | undefined, language: string): string | undefined {
  if (size === undefined || !Number.isFinite(size) || size < 0) return undefined;
  const units = ["byte", "kilobyte", "megabyte", "gigabyte", "terabyte", "petabyte"] as const;
  const exponent = Math.min(units.length - 1, Math.max(0, Math.floor(Math.log(size || 1) / Math.log(1024))));
  return new Intl.NumberFormat(language, {
    style: "unit",
    unit: units[exponent],
    unitDisplay: "short",
    maximumFractionDigits: 1,
  }).format(size / 1024 ** exponent);
}
