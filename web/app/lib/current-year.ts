export async function getCurrentYear(): Promise<number> {
  "use cache";

  return new Date().getFullYear();
}
