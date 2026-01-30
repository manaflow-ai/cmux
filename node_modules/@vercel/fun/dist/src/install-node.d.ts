/// <reference types="node" />
export declare function generateNodeTarballUrl(version: string, platform?: NodeJS.Platform, arch?: string): string;
export declare function installNode(dest: string, version: string, platform?: NodeJS.Platform, arch?: string): Promise<void>;
