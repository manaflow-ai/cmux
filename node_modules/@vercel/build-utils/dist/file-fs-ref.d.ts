/// <reference types="node" />
import { FileBase } from './types';
interface FileFsRefOptions {
    mode?: number;
    contentType?: string;
    fsPath: string;
    size?: number;
}
interface FromStreamOptions {
    mode: number;
    contentType?: string;
    stream: NodeJS.ReadableStream;
    fsPath: string;
}
declare class FileFsRef implements FileBase {
    type: 'FileFsRef';
    mode: number;
    fsPath: string;
    size?: number;
    contentType: string | undefined;
    constructor({ mode, contentType, fsPath, size, }: FileFsRefOptions);
    static fromFsPath({ mode, contentType, fsPath, size, }: FileFsRefOptions): Promise<FileFsRef>;
    static fromStream({ mode, contentType, stream, fsPath, }: FromStreamOptions): Promise<FileFsRef>;
    toStreamAsync(): Promise<NodeJS.ReadableStream>;
    toStream(): NodeJS.ReadableStream;
}
export default FileFsRef;
