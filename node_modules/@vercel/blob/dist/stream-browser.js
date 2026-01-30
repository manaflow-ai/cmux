// This file is here because Edge Functions have no support for Node.js streams by default
// It's unlikely someone would try to read/use a Node.js stream in an Edge function but we still put
// a message in case this happens

export const Readable = {
  toWeb() {
    throw new Error(
      'Vercel Blob: Sorry, we cannot get a Readable stream in this environment. If you see this message please open an issue here: https://github.com/vercel/storage/ with details on your environment.',
    );
  },
};
