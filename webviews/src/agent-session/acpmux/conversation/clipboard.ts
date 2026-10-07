/// Copies `text`: the async clipboard where the page may use it, else a selection copy
/// (a WKWebView page loaded from a file is not always allowed the async clipboard).
export async function copyText(text: string): Promise<void> {
  try {
    await navigator.clipboard.writeText(text);
  } catch {
    const field = document.createElement("textarea");
    field.value = text;
    field.style.position = "fixed";
    field.style.opacity = "0";
    document.body.append(field);
    field.select();
    document.execCommand("copy");
    field.remove();
  }
}

/// Copies an image as PNG (an SVG or JPEG source is drawn to a canvas first). The blob is handed
/// over as a promise so WebKit still counts the click that started the copy. An image that cannot
/// be drawn (no size, no 2D context, a tainted canvas) fails the copy rather than leaving it
/// pending or copying a blank.
export async function copyImage(src: string): Promise<void> {
  const png = new Promise<Blob>((resolve, reject) => {
    const image = new Image();
    image.onload = () => {
      try {
        if (!image.naturalWidth || !image.naturalHeight) throw new Error("image.size");
        const canvas = document.createElement("canvas");
        canvas.width = image.naturalWidth;
        canvas.height = image.naturalHeight;
        const context = canvas.getContext("2d");
        if (!context) throw new Error("image.canvas");
        context.drawImage(image, 0, 0);
        canvas.toBlob((blob) => (blob ? resolve(blob) : reject(new Error("image.encode"))), "image/png");
      } catch (error) {
        reject(error instanceof Error ? error : new Error("image.draw"));
      }
    };
    image.onerror = () => reject(new Error("image.decode"));
    image.src = src;
  });
  await navigator.clipboard.write([new ClipboardItem({ "image/png": png })]);
}
