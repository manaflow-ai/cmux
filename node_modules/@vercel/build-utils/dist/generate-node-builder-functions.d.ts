import { BuildV3, Config } from './types';
import type FileFsRef from './file-fs-ref';
export declare function generateNodeBuilderFunctions(frameworkName: string, regex: RegExp, validFilenames: string[], validExtensions: string[], nodeBuild: any, // necessary to avoid circular dependency
opts?: {
    checks?: (info: {
        config: Config;
        isBun: boolean;
    }) => void;
}): {
    require_: NodeRequire;
    findEntrypoint: (files: Record<string, FileFsRef>) => {
        entrypoint: string;
        entrypointsNotMatchingRegex: string[];
    };
    build: BuildV3;
    entrypointCallback: (args: Parameters<BuildV3>[0]) => Promise<string>;
};
