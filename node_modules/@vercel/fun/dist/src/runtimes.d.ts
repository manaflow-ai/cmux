import { Runtime } from './types';
interface Runtimes {
    [name: string]: Runtime;
}
export declare const runtimes: Runtimes;
export declare const funCacheDir: string;
export declare function initializeRuntime(target: string | Runtime): Promise<Runtime>;
export {};
