import Link from "next/link";
import { DevboxCreator } from "./devbox-creator";

export default function DevboxPage() {
  return (
    <main className="min-h-screen px-5 py-6 sm:px-8">
      <div className="mx-auto flex min-h-[calc(100vh-3rem)] w-full max-w-3xl flex-col">
        <header className="flex items-center justify-between gap-4 text-sm">
          <Link href="/" className="font-semibold tracking-tight">
            devbox.new
          </Link>
          <a
            href="https://cmux.com"
            className="text-muted transition-colors hover:text-foreground"
          >
            cmux
          </a>
        </header>

        <section className="flex flex-1 items-center justify-center py-16">
          <DevboxCreator />
        </section>
      </div>
    </main>
  );
}
