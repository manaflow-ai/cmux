// The bookmark glyphs the Bookmarks page and the bookmarks bar share: a folder and a page without
// a favicon, drawn in the current text color.

export function FolderGlyph() {
  return (
    <svg viewBox="0 0 16 16" width="16" height="16">
      <path
        d="M1.75 4.25c0-.83.67-1.5 1.5-1.5h2.9l1.5 1.5h5.1c.83 0 1.5.67 1.5 1.5v6c0 .83-.67 1.5-1.5 1.5H3.25c-.83 0-1.5-.67-1.5-1.5z"
        fill="none"
        stroke="currentColor"
        strokeWidth="1.2"
        strokeLinejoin="round"
      />
    </svg>
  );
}

export function GlobeGlyph() {
  return (
    <svg viewBox="0 0 16 16" width="16" height="16">
      <g fill="none" stroke="currentColor" strokeWidth="1.1">
        <circle cx="8" cy="8" r="6.25" />
        <ellipse cx="8" cy="8" rx="2.6" ry="6.25" />
        <path d="M1.9 6h12.2M1.9 10h12.2" />
      </g>
    </svg>
  );
}
