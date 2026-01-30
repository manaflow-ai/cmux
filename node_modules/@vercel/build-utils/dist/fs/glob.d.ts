import FileFsRef from '../file-fs-ref';
export interface GlobOptions {
    cwd?: string;
    dot?: boolean;
    follow?: boolean;
    ignore?: string | ReadonlyArray<string>;
    includeDirectories?: boolean;
    nodir?: boolean;
}
export default function glob(pattern: string, opts: GlobOptions | string, mountpoint?: string): Promise<Record<string, FileFsRef>>;
