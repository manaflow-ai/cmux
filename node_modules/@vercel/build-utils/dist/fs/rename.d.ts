import { Files } from '../types';
type Delegate = (name: string) => string;
/**
 * Renames the keys of a `Files` map.
 *
 * @param files A map of filenames to `File` instances
 * @param delegate A function that returns the new filename
 * @returns A new file map with the renamed filenames
 */
export default function rename(files: Files, delegate: Delegate): Files;
export {};
