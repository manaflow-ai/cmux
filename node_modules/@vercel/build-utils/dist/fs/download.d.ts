import FileFsRef from '../file-fs-ref';
import { File, Files, Meta } from '../types';
export interface DownloadedFiles {
    [filePath: string]: FileFsRef;
}
export declare function isDirectory(mode: number): boolean;
export declare function isSymbolicLink(mode: number): boolean;
export declare function downloadFile(file: File, fsPath: string): Promise<FileFsRef>;
export default function download(files: Files, basePath: string, meta?: Meta): Promise<DownloadedFiles>;
