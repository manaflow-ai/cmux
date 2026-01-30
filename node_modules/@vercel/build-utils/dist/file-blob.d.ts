/// <reference types="node" />
/// <reference types="node" />
import { FileBase } from './types';
interface FileBlobOptions {
    mode?: number;
    contentType?: string;
    data: string | Buffer;
}
interface FromStreamOptions {
    mode?: number;
    contentType?: string;
    stream: NodeJS.ReadableStream;
}
export default class FileBlob implements FileBase {
    type: 'FileBlob';
    mode: number;
    data: string | Buffer;
    contentType: string | undefined;
    constructor({ mode, contentType, data }: FileBlobOptions);
    static fromStream({ mode, contentType, stream, }: FromStreamOptions): Promise<FileBlob>;
    toStreamAsync(): Promise<NodeJS.ReadableStream>;
    toStream(): NodeJS.ReadableStream;
}
export {};
