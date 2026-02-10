export function DownloadButton({ size = "default" }: { size?: "default" | "sm" }) {
  const isSmall = size === "sm";
  return (
    <a
      href="https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg"
      className={`inline-flex items-center whitespace-nowrap rounded-full font-medium bg-foreground hover:opacity-85 transition-opacity ${
        isSmall ? "gap-2 px-4 py-1.5 text-xs" : "gap-2.5 px-5 py-2.5 text-[15px]"
      }`}
      style={{ color: "var(--background)", textDecoration: "none" }}
    >
      <svg
        width={isSmall ? 12 : 16}
        height={isSmall ? 14 : 19}
        viewBox="0 0 814 1000"
        fill="currentColor"
      >
        <path d="M788.1 340.9c-5.8 4.5-108.2 62.2-108.2 190.5 0 148.4 130.3 200.9 134.2 202.2-.6 3.2-20.7 71.9-68.7 141.9-42.8 61.6-87.5 123.1-155.5 123.1s-85.5-39.5-164-39.5c-76.5 0-103.7 40.8-165.9 40.8s-105.6-57.8-155.5-127.4c-58.3-81.6-105.6-208.4-105.6-328.6 0-193 125.6-295.5 249.2-295.5 65.7 0 120.5 43.1 161.7 43.1 39.2 0 100.4-45.8 175.1-45.8 28.3 0 130.3 2.6 197.2 99.2zM554.1 159.4c31.1-36.9 53.1-88.1 53.1-139.3 0-7.1-.6-14.3-1.9-20.1-50.6 1.9-110.8 33.7-147.1 75.8-28.9 32.4-57.2 83.6-57.2 135.4 0 7.8 1.3 15.6 1.9 18.1 3.2.6 8.4 1.3 13.6 1.3 45.4 0 102.5-30.4 137.6-71.2z" />
      </svg>
      Download for Mac
    </a>
  );
}
