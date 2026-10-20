export function makeMixedPatch(count: number): string {
  let result = "";
  for (let index = 0; index < count; index += 1) {
    const path = `src/generated/group-${index % 100}/file-${index}.ts`;
    switch (index % 7) {
    case 0:
      result += modifiedPatch(path, index);
      break;
    case 1:
      result += addedPatch(path, index);
      break;
    case 2:
      result += deletedPatch(path, index);
      break;
    case 3:
      result += pureRenamePatch(path, index);
      break;
    case 4:
      result += changedRenamePatch(path, index);
      break;
    case 5:
      result += modePatch(path);
      break;
    default:
      result += binaryPatch(path);
      break;
    }
  }
  return result;
}

function modifiedPatch(path: string, index: number): string {
  return lines([
    `diff --git a/${path} b/${path}`,
    "index 1111111..2222222 100644",
    `--- a/${path}`,
    `+++ b/${path}`,
    "@@ -1,3 +1,3 @@",
    ` export const id = ${index};`,
    "-export const state = \"old\";",
    "+export const state = \"new\";",
    " export const enabled = true;",
    "@@ -20,2 +20,3 @@ export function tail() {",
    "   return true;",
    `+  // ${"x".repeat(index % 31)}`,
    " }",
  ]);
}

function addedPatch(path: string, index: number): string {
  return lines([
    `diff --git a/${path} b/${path}`,
    "new file mode 100644",
    "index 0000000..2222222",
    "--- /dev/null",
    `+++ b/${path}`,
    "@@ -0,0 +1,2 @@",
    `+export const id = ${index};`,
    "+export const added = true;",
  ]);
}

function deletedPatch(path: string, index: number): string {
  return lines([
    `diff --git a/${path} b/${path}`,
    "deleted file mode 100644",
    "index 1111111..0000000",
    `--- a/${path}`,
    "+++ /dev/null",
    "@@ -1,2 +0,0 @@",
    `-export const id = ${index};`,
    "-export const removed = true;",
  ]);
}

function pureRenamePatch(path: string, index: number): string {
  const previous = `src/generated/old/file-${index}.ts`;
  return lines([
    `diff --git a/${previous} b/${path}`,
    "similarity index 100%",
    `rename from ${previous}`,
    `rename to ${path}`,
  ]);
}

function changedRenamePatch(path: string, index: number): string {
  const previous = `src/generated/old/file-${index}.ts`;
  return lines([
    `diff --git a/${previous} b/${path}`,
    "similarity index 80%",
    `rename from ${previous}`,
    `rename to ${path}`,
    "index 1111111..2222222 100644",
    `--- a/${previous}`,
    `+++ b/${path}`,
    "@@ -1 +1,2 @@",
    ` export const id = ${index};`,
    "+export const renamed = true;",
  ]);
}

function modePatch(path: string): string {
  return lines([
    `diff --git a/${path} b/${path}`,
    "old mode 100644",
    "new mode 100755",
  ]);
}

function binaryPatch(path: string): string {
  return lines([
    `diff --git a/${path} b/${path}`,
    "index 1111111111111111111111111111111111111111..2222222222222222222222222222222222222222 100644",
    "GIT binary patch",
    "literal 5",
    "McmZQz<YZ<6001rk5&!@I",
    "",
    "literal 4",
    "LcmZQzWMT#Y01f~L",
  ]);
}

function lines(value: string[]): string {
  return `${value.join("\n")}\n`;
}
