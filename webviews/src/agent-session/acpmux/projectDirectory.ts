export type ProjectDirectory = {
  path: string;
  parent: string | null;
  home: string;
  directories: string[];
};
export type ProjectDirectoryHost = {
  /** Optional in-pane browser supplied by gallery or the reviewed native host operation. */
  list?: (path: string) => Promise<ProjectDirectory>;
  reveal?: (path: string) => Promise<unknown>;
};

export const projectDirectoryHost: ProjectDirectoryHost = {
  list: (path) =>
    import("./native").then(({ postNative }) =>
      postNative<ProjectDirectory>("project.listDirectory", { path }),
    ),
  reveal: async (path) => (await import("./native")).postNative("link.openPath", { path }),
};

export function directoryName(path: string): string {
  return path.split("/").filter(Boolean).at(-1) ?? path;
}
