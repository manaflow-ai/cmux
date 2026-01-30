import { e as CommonCreateBlobOptions, W as WithUploadProgress, f as BlobError, B as BlobCommandOptions, P as PutBody, a as PutBlobResult, b as Part, U as UploadPartCommandOptions, g as CompleteMultipartUploadCommandOptions } from './create-folder-C02EFEPE.js';
export { O as OnUploadProgressCallback, j as PartInput, i as UploadProgressEvent, d as createFolder, h as getDownloadUrl } from './create-folder-C02EFEPE.js';
import 'stream';
import 'undici';

interface PutCommandOptions extends CommonCreateBlobOptions, WithUploadProgress {
    /**
     * Whether to use multipart upload. Use this when uploading large files. It will split the file into multiple parts, upload them in parallel and retry failed parts.
     * @defaultvalue false
     */
    multipart?: boolean;
}

declare class BlobAccessError extends BlobError {
    constructor();
}
declare class BlobContentTypeNotAllowedError extends BlobError {
    constructor(message: string);
}
declare class BlobPathnameMismatchError extends BlobError {
    constructor(message: string);
}
declare class BlobClientTokenExpiredError extends BlobError {
    constructor();
}
declare class BlobFileTooLargeError extends BlobError {
    constructor(message: string);
}
declare class BlobStoreNotFoundError extends BlobError {
    constructor();
}
declare class BlobStoreSuspendedError extends BlobError {
    constructor();
}
declare class BlobUnknownError extends BlobError {
    constructor();
}
declare class BlobNotFoundError extends BlobError {
    constructor();
}
declare class BlobServiceNotAvailable extends BlobError {
    constructor();
}
declare class BlobServiceRateLimited extends BlobError {
    readonly retryAfter: number;
    constructor(seconds?: number);
}
declare class BlobRequestAbortedError extends BlobError {
    constructor();
}

/**
 * Deletes one or multiple blobs from your store.
 * Detailed documentation can be found here: https://vercel.com/docs/vercel-blob/using-blob-sdk#delete-a-blob
 *
 * @param url - Blob url or array of blob urls that identify the blobs to be deleted. You can only delete blobs that are located in a store, that your 'BLOB_READ_WRITE_TOKEN' has access to.
 * @param options - Additional options for the request.
 */
declare function del(url: string[] | string, options?: BlobCommandOptions): Promise<void>;

/**
 * Result of the head method containing metadata about a blob.
 */
interface HeadBlobResult {
    /**
     * The size of the blob in bytes.
     */
    size: number;
    /**
     * The date when the blob was uploaded.
     */
    uploadedAt: Date;
    /**
     * The pathname of the blob within the store.
     */
    pathname: string;
    /**
     * The content type of the blob.
     */
    contentType: string;
    /**
     * The content disposition header value.
     */
    contentDisposition: string;
    /**
     * The URL of the blob.
     */
    url: string;
    /**
     * A URL that will cause browsers to download the file instead of displaying it inline.
     */
    downloadUrl: string;
    /**
     * The cache control header value.
     */
    cacheControl: string;
}
/**
 * Fetches metadata of a blob object.
 * Detailed documentation can be found here: https://vercel.com/docs/vercel-blob/using-blob-sdk#get-blob-metadata
 *
 * @param url - Blob url to lookup.
 * @param options - Additional options for the request.
 */
declare function head(url: string, options?: BlobCommandOptions): Promise<HeadBlobResult>;

/**
 * Basic blob object information returned by the list method.
 */
interface ListBlobResultBlob {
    /**
     * The URL of the blob.
     */
    url: string;
    /**
     * A URL that will cause browsers to download the file instead of displaying it inline.
     */
    downloadUrl: string;
    /**
     * The pathname of the blob within the store.
     */
    pathname: string;
    /**
     * The size of the blob in bytes.
     */
    size: number;
    /**
     * The date when the blob was uploaded.
     */
    uploadedAt: Date;
}
/**
 * Result of the list method in expanded mode (default).
 */
interface ListBlobResult {
    /**
     * Array of blob objects in the store.
     */
    blobs: ListBlobResultBlob[];
    /**
     * Pagination cursor for the next set of results, if hasMore is true.
     */
    cursor?: string;
    /**
     * Indicates if there are more results available.
     */
    hasMore: boolean;
}
/**
 * Result of the list method in folded mode.
 */
interface ListFoldedBlobResult extends ListBlobResult {
    /**
     * Array of folder paths in the store.
     */
    folders: string[];
}
/**
 * Options for the list method.
 */
interface ListCommandOptions<M extends 'expanded' | 'folded' | undefined = undefined> extends BlobCommandOptions {
    /**
     * The maximum number of blobs to return.
     * @defaultvalue 1000
     */
    limit?: number;
    /**
     * Filters the result to only include blobs that start with this prefix.
     * If used together with `mode: 'folded'`, make sure to include a trailing slash after the foldername.
     */
    prefix?: string;
    /**
     * The cursor to use for pagination. Can be obtained from the response of a previous `list` request.
     */
    cursor?: string;
    /**
     * Defines how the blobs are listed
     * - `expanded` the blobs property contains all blobs.
     * - `folded` the blobs property contains only the blobs at the root level of your store. Blobs that are located inside a folder get merged into a single entry in the folder response property.
     * @defaultvalue 'expanded'
     */
    mode?: M;
}
/**
 * @internal Type helper to determine the return type based on the mode parameter.
 */
type ListCommandResult<M extends 'expanded' | 'folded' | undefined = undefined> = M extends 'folded' ? ListFoldedBlobResult : ListBlobResult;
/**
 * Fetches a paginated list of blob objects from your store.
 *
 * @param options - Configuration options including:
 *   - token - (Optional) A string specifying the read-write token to use when making requests. It defaults to process.env.BLOB_READ_WRITE_TOKEN when deployed on Vercel.
 *   - limit - (Optional) The maximum number of blobs to return. Defaults to 1000.
 *   - prefix - (Optional) Filters the result to only include blobs that start with this prefix. If used with mode: 'folded', include a trailing slash after the folder name.
 *   - cursor - (Optional) The cursor to use for pagination. Can be obtained from the response of a previous list request.
 *   - mode - (Optional) Defines how the blobs are listed. Can be 'expanded' (default) or 'folded'. In folded mode, blobs located inside a folder are merged into a single entry in the folders response property.
 *   - abortSignal - (Optional) AbortSignal to cancel the operation.
 * @returns A promise that resolves to an object containing:
 *   - blobs: An array of blob objects with size, uploadedAt, pathname, url, and downloadUrl properties
 *   - cursor: A string for pagination (if hasMore is true)
 *   - hasMore: A boolean indicating if there are more results available
 *   - folders: (Only in 'folded' mode) An array of folder paths
 */
declare function list<M extends 'expanded' | 'folded' | undefined = undefined>(options?: ListCommandOptions<M>): Promise<ListCommandResult<M>>;

type CopyCommandOptions = CommonCreateBlobOptions;
interface CopyBlobResult {
    url: string;
    downloadUrl: string;
    pathname: string;
    contentType: string;
    contentDisposition: string;
}
/**
 * Copies a blob to another location in your store.
 * Detailed documentation can be found here: https://vercel.com/docs/vercel-blob/using-blob-sdk#copy-a-blob
 *
 * @param fromUrl - The blob URL to copy. You can only copy blobs that are in the store, that your 'BLOB_READ_WRITE_TOKEN' has access to.
 * @param toPathname - The pathname to copy the blob to. This includes the filename.
 * @param options - Additional options. The copy method will not preserve any metadata configuration (e.g.: 'cacheControlMaxAge') of the source blob. If you want to copy the metadata, you need to define it here again.
 */
declare function copy(fromUrl: string, toPathname: string, options: CopyCommandOptions): Promise<CopyBlobResult>;

/**
 * Uploads a blob into your store from your server.
 * Detailed documentation can be found here: https://vercel.com/docs/vercel-blob/using-blob-sdk#upload-a-blob
 *
 * If you want to upload from the browser directly, or if you're hitting Vercel upload limits, check out the documentation for client uploads: https://vercel.com/docs/vercel-blob/using-blob-sdk#client-uploads
 *
 * @param pathname - The pathname to upload the blob to, including the extension. This will influence the URL of your blob like https://$storeId.public.blob.vercel-storage.com/$pathname.
 * @param body - The content of your blob, can be a: string, File, Blob, Buffer or Stream. We support almost everything fetch supports: https://developer.mozilla.org/en-US/docs/Web/API/RequestInit#body.
 * @param options - Configuration options including:
 *   - access - (Required) Must be 'public' as blobs are publicly accessible.
 *   - addRandomSuffix - (Optional) A boolean specifying whether to add a random suffix to the pathname. It defaults to false. We recommend using this option to ensure there are no conflicts in your blob filenames.
 *   - allowOverwrite - (Optional) A boolean to allow overwriting blobs. By default an error will be thrown if you try to overwrite a blob by using the same pathname for multiple blobs.
 *   - contentType - (Optional) A string indicating the media type. By default, it's extracted from the pathname's extension.
 *   - cacheControlMaxAge - (Optional) A number in seconds to configure how long Blobs are cached. Defaults to one month. Cannot be set to a value lower than 1 minute.
 *   - token - (Optional) A string specifying the token to use when making requests. It defaults to process.env.BLOB_READ_WRITE_TOKEN when deployed on Vercel.
 *   - multipart - (Optional) Whether to use multipart upload for large files. It will split the file into multiple parts, upload them in parallel and retry failed parts.
 *   - abortSignal - (Optional) AbortSignal to cancel the operation.
 *   - onUploadProgress - (Optional) Callback to track upload progress: onUploadProgress(\{loaded: number, total: number, percentage: number\})
 * @returns A promise that resolves to the blob information, including pathname, contentType, contentDisposition, url, and downloadUrl.
 */
declare const put: (pathname: string, body: PutBody, optionsInput: PutCommandOptions) => Promise<PutBlobResult>;

/**
 * Creates a multipart upload. This is the first step in the manual multipart upload process.
 *
 * @param pathname - A string specifying the path inside the blob store. This will be the base value of the return URL and includes the filename and extension.
 * @param options - Configuration options including:
 *   - access - (Required) Must be 'public' as blobs are publicly accessible.
 *   - addRandomSuffix - (Optional) A boolean specifying whether to add a random suffix to the pathname. It defaults to true.
 *   - allowOverwrite - (Optional) A boolean to allow overwriting blobs. By default an error will be thrown if you try to overwrite a blob by using the same pathname for multiple blobs.
 *   - contentType - (Optional) The media type for the file. If not specified, it's derived from the file extension. Falls back to application/octet-stream when no extension exists or can't be matched.
 *   - cacheControlMaxAge - (Optional) A number in seconds to configure the edge and browser cache. Defaults to one year.
 *   - token - (Optional) A string specifying the token to use when making requests. It defaults to process.env.BLOB_READ_WRITE_TOKEN when deployed on Vercel.
 *   - abortSignal - (Optional) AbortSignal to cancel the operation.
 * @returns A promise that resolves to an object containing:
 *   - key: A string that identifies the blob object.
 *   - uploadId: A string that identifies the multipart upload. Both are needed for subsequent uploadPart calls.
 */
declare const createMultipartUpload: (pathname: string, optionsInput: CommonCreateBlobOptions) => Promise<{
    key: string;
    uploadId: string;
}>;
/**
 * Creates a multipart uploader that simplifies the multipart upload process.
 * This is a wrapper around the manual multipart upload process that provides a more convenient API.
 *
 * @param pathname - A string specifying the path inside the blob store. This will be the base value of the return URL and includes the filename and extension.
 * @param options - Configuration options including:
 *   - access - (Required) Must be 'public' as blobs are publicly accessible.
 *   - addRandomSuffix - (Optional) A boolean specifying whether to add a random suffix to the pathname. It defaults to true.
 *   - allowOverwrite - (Optional) A boolean to allow overwriting blobs. By default an error will be thrown if you try to overwrite a blob by using the same pathname for multiple blobs.
 *   - contentType - (Optional) The media type for the file. If not specified, it's derived from the file extension. Falls back to application/octet-stream when no extension exists or can't be matched.
 *   - cacheControlMaxAge - (Optional) A number in seconds to configure the edge and browser cache. Defaults to one year.
 *   - token - (Optional) A string specifying the token to use when making requests. It defaults to process.env.BLOB_READ_WRITE_TOKEN when deployed on Vercel.
 *   - abortSignal - (Optional) AbortSignal to cancel the operation.
 * @returns A promise that resolves to an uploader object with the following properties and methods:
 *   - key: A string that identifies the blob object.
 *   - uploadId: A string that identifies the multipart upload.
 *   - uploadPart: A method to upload a part of the file.
 *   - complete: A method to complete the multipart upload process.
 */
declare const createMultipartUploader: (pathname: string, optionsInput: CommonCreateBlobOptions) => Promise<{
    key: string;
    uploadId: string;
    uploadPart(partNumber: number, body: PutBody): Promise<{
        etag: string;
        partNumber: number;
    }>;
    complete(parts: Part[]): Promise<PutBlobResult>;
}>;

/**
 * Uploads a part of a multipart upload.
 * Used as part of the manual multipart upload process.
 *
 * @param pathname - Same value as the pathname parameter passed to createMultipartUpload. This will influence the final URL of your blob.
 * @param body - A blob object as ReadableStream, String, ArrayBuffer or Blob based on these supported body types. Each part must be a minimum of 5MB, except the last one which can be smaller.
 * @param options - Configuration options including:
 *   - access - (Required) Must be 'public' as blobs are publicly accessible.
 *   - uploadId - (Required) A string returned from createMultipartUpload which identifies the multipart upload.
 *   - key - (Required) A string returned from createMultipartUpload which identifies the blob object.
 *   - partNumber - (Required) A number identifying which part is uploaded (1-based index).
 *   - contentType - (Optional) The media type for the blob. By default, it's derived from the pathname.
 *   - token - (Optional) A string specifying the token to use when making requests. It defaults to process.env.BLOB_READ_WRITE_TOKEN when deployed on Vercel.
 *   - addRandomSuffix - (Optional) A boolean specifying whether to add a random suffix to the pathname.
 *   - allowOverwrite - (Optional) A boolean to allow overwriting blobs.
 *   - cacheControlMaxAge - (Optional) A number in seconds to configure how long Blobs are cached.
 *   - abortSignal - (Optional) AbortSignal to cancel the running request.
 *   - onUploadProgress - (Optional) Callback to track upload progress: onUploadProgress(\{loaded: number, total: number, percentage: number\})
 * @returns A promise that resolves to the uploaded part information containing etag and partNumber, which will be needed for the completeMultipartUpload call.
 */
declare const uploadPart: (pathname: string, body: PutBody, optionsInput: UploadPartCommandOptions) => Promise<Part>;

/**
 * Completes a multipart upload by combining all uploaded parts.
 * This is the final step in the manual multipart upload process.
 *
 * @param pathname - Same value as the pathname parameter passed to createMultipartUpload.
 * @param parts - An array containing all the uploaded parts information from previous uploadPart calls. Each part must have properties etag and partNumber.
 * @param options - Configuration options including:
 *   - access - (Required) Must be 'public' as blobs are publicly accessible.
 *   - uploadId - (Required) A string returned from createMultipartUpload which identifies the multipart upload.
 *   - key - (Required) A string returned from createMultipartUpload which identifies the blob object.
 *   - contentType - (Optional) The media type for the file. If not specified, it's derived from the file extension.
 *   - token - (Optional) A string specifying the token to use when making requests. It defaults to process.env.BLOB_READ_WRITE_TOKEN when deployed on Vercel.
 *   - addRandomSuffix - (Optional) A boolean specifying whether to add a random suffix to the pathname. It defaults to true.
 *   - allowOverwrite - (Optional) A boolean to allow overwriting blobs.
 *   - cacheControlMaxAge - (Optional) A number in seconds to configure the edge and browser cache. Defaults to one year.
 *   - abortSignal - (Optional) AbortSignal to cancel the operation.
 * @returns A promise that resolves to the finalized blob information, including pathname, contentType, contentDisposition, url, and downloadUrl.
 */
declare const completeMultipartUpload: (pathname: string, parts: Part[], optionsInput: CompleteMultipartUploadCommandOptions) => Promise<PutBlobResult>;

export { BlobAccessError, BlobClientTokenExpiredError, BlobContentTypeNotAllowedError, BlobError, BlobFileTooLargeError, BlobNotFoundError, BlobPathnameMismatchError, BlobRequestAbortedError, BlobServiceNotAvailable, BlobServiceRateLimited, BlobStoreNotFoundError, BlobStoreSuspendedError, BlobUnknownError, CompleteMultipartUploadCommandOptions, type CopyBlobResult, type CopyCommandOptions, type HeadBlobResult, type ListBlobResult, type ListBlobResultBlob, type ListCommandOptions, type ListFoldedBlobResult, Part, PutBlobResult, type PutCommandOptions, UploadPartCommandOptions, completeMultipartUpload, copy, createMultipartUpload, createMultipartUploader, del, head, list, put, uploadPart };
