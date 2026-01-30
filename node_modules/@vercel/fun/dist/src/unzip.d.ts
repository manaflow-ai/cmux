/// <reference types="node" />
/// <reference types="node" />
import { ZipFile, open as zipFromFile, fromBuffer as zipFromBuffer } from 'yauzl-promise';
export { zipFromFile, zipFromBuffer, ZipFile };
export declare function unzipToTemp(data: Buffer | string, tmpDir?: string): Promise<string>;
interface UnzipOptions {
    strip?: number;
}
export declare function unzip(zipFile: ZipFile, dir: string, opts?: UnzipOptions): Promise<void>;
