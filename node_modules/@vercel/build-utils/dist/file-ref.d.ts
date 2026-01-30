/// <reference types="node" />
import { FileBase } from './types';
interface FileRefOptions {
    mode?: number;
    digest: string;
    contentType?: string;
    mutable?: boolean;
}
export default class FileRef implements FileBase {
    type: 'FileRef';
    mode: number;
    digest: string;
    contentType: string | undefined;
    private mutable;
    constructor({ mode, digest, contentType, mutable, }: FileRefOptions);
    /**
     * Retrieves the URL of the CloudFront distribution for the S3
     * bucket represented by {@link getNowFilesS3Url}.
     *
     * @returns The URL of the CloudFront distribution
     */
    private getNowFilesCloudfrontUrl;
    /**
     * Retrieves the URL of the S3 bucket for storing ephemeral files.
     *
     * @returns The URL of the S3 bucket
     */
    private getNowEphemeralFilesS3Url;
    /**
     * Retrieves the URL of the S3 bucket for storing files.
     *
     * @returns The URL of the S3 bucket
     */
    private getNowFilesS3Url;
    toStreamAsync(): Promise<NodeJS.ReadableStream>;
    toStream(): NodeJS.ReadableStream;
}
export {};
