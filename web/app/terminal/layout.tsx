export default function TerminalLayout({
  children,
}: {
  children: React.ReactNode
}) {
  return (
    <>
      <style>{`html, body { overflow: hidden; overscroll-behavior: none; height: 100%; }`}</style>
      <div
        className="dark"
        style={{
          position: "fixed",
          inset: 0,
          overflow: "hidden",
        }}
      >
        {children}
      </div>
    </>
  )
}
