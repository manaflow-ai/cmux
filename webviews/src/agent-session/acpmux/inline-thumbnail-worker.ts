type ThumbnailRequest = { id: number; mimeType: string; data: string; height: number };
type ThumbnailResponse = {
  id: number;
  result?: { url: string; width: number; height: number };
};

function bytesFromBase64(value: string): ArrayBuffer {
  const binary = atob(value);
  const bytes = new Uint8Array(binary.length);
  for (let index = 0; index < binary.length; index += 1) bytes[index] = binary.charCodeAt(index);
  return bytes.buffer;
}

function base64(bytes: Uint8Array): string {
  let binary = "";
  for (let index = 0; index < bytes.length; index += 0x8000)
    binary += String.fromCharCode(...bytes.subarray(index, index + 0x8000));
  return btoa(binary);
}

self.onmessage = async (event: MessageEvent<ThumbnailRequest>) => {
  const { id, mimeType, data, height } = event.data;
  try {
    const bitmap = await createImageBitmap(new Blob([bytesFromBase64(data)], { type: mimeType }));
    if (!bitmap.width || !bitmap.height) {
      bitmap.close();
      self.postMessage({ id } satisfies ThumbnailResponse);
      return;
    }
    const ratio = Math.min(2, Math.max(0.7, bitmap.width / bitmap.height));
    const sourceWidth = bitmap.width / bitmap.height > ratio ? bitmap.height * ratio : bitmap.width;
    const sourceHeight = bitmap.width / bitmap.height > ratio ? bitmap.height : bitmap.width / ratio;
    const canvas = new OffscreenCanvas(Math.round(height * ratio), height);
    const context = canvas.getContext("2d");
    if (!context) {
      bitmap.close();
      self.postMessage({ id } satisfies ThumbnailResponse);
      return;
    }
    context.drawImage(
      bitmap,
      (bitmap.width - sourceWidth) / 2,
      (bitmap.height - sourceHeight) / 2,
      sourceWidth,
      sourceHeight,
      0,
      0,
      canvas.width,
      canvas.height,
    );
    const natural = { width: bitmap.width, height: bitmap.height };
    bitmap.close();
    const output = await canvas.convertToBlob({ type: "image/png" });
    const result = {
      url: `data:image/png;base64,${base64(new Uint8Array(await output.arrayBuffer()))}`,
      ...natural,
    };
    self.postMessage({ id, result } satisfies ThumbnailResponse);
  } catch {
    self.postMessage({ id } satisfies ThumbnailResponse);
  }
};
