function decodeBase64(value) {
  try {
    return globalThis.atob(String(value || ""));
  } catch {
    return "";
  }
}

function decodeDataPayload(payload, base64) {
  if (base64) return decodeBase64(payload);
  try {
    return decodeURIComponent(payload);
  } catch {
    return "";
  }
}

function dataImageCanLoad(url) {
  const match = String(url || "").match(/^data:(image\/[a-z0-9.+-]+)(;base64)?,([\s\S]*)$/i);
  if (!match) return null;
  const mime = match[1].toLowerCase();
  const base64 = Boolean(match[2]);
  const payload = match[3] || "";
  const decoded = decodeDataPayload(payload, base64);
  if (!decoded) return false;
  if (mime === "image/svg+xml") return /<svg[\s>]/i.test(decoded);
  if (!base64) return false;
  if (mime === "image/png") return decoded.startsWith("\x89PNG\r\n\x1a\n");
  if (mime === "image/jpeg" || mime === "image/jpg") return decoded.startsWith("\xff\xd8\xff");
  if (mime === "image/gif") return decoded.startsWith("GIF87a") || decoded.startsWith("GIF89a");
  if (mime === "image/webp") return decoded.startsWith("RIFF") && decoded.slice(8, 12) === "WEBP";
  if (mime === "image/avif") return decoded.includes("ftypavif") || decoded.includes("ftypavis");
  return true;
}

export function canLoadImage(src, timeoutMs = 3500) {
  const url = String(src || "").trim();
  if (!url) return Promise.resolve(false);
  const dataImageResult = dataImageCanLoad(url);
  if (dataImageResult !== null) return Promise.resolve(dataImageResult);
  return new Promise((resolve) => {
    const image = new Image();
    let settled = false;
    const finish = (ok) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      image.onload = null;
      image.onerror = null;
      resolve(ok);
    };
    const timer = setTimeout(() => finish(false), timeoutMs);
    image.onload = () => finish(image.naturalWidth > 0 && image.naturalHeight > 0);
    image.onerror = () => finish(false);
    try {
      image.src = url;
    } catch {
      finish(false);
    }
  });
}
