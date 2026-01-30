/// <reference types="node" />
export declare function generatePythonTarballUrl(version: string, platform?: NodeJS.Platform, arch?: string): string;
export declare function installPython(dest: string, version: string, platform?: NodeJS.Platform, arch?: string): Promise<void>;
