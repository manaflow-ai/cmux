//! The daemon reads its registry from several SQLite connections at once (a reader per
//! request, the writer, the journal). SQLite built with ENABLE_MEMORY_MANAGEMENT puts the page
//! caches of all connections in one group behind one global mutex, so concurrent `tab.list`
//! readers spend most of their time waiting for it (2026-11-14 profile: about 70% of the
//! handler). Without that option each connection keeps its own page cache.

use rusqlite::Connection;

#[test]
fn each_sqlite_connection_keeps_its_own_page_cache() {
    let connection = Connection::open_in_memory().expect("open an in-memory database");
    let options = connection
        .prepare("PRAGMA compile_options")
        .expect("prepare PRAGMA compile_options")
        .query_map([], |row| row.get::<_, String>(0))
        .expect("read PRAGMA compile_options")
        .collect::<Result<Vec<_>, _>>()
        .expect("compile options are text");
    assert!(
        !options.iter().any(|option| option == "ENABLE_MEMORY_MANAGEMENT"),
        "the bundled SQLite shares one page cache and one mutex between all connections \
         (ENABLE_MEMORY_MANAGEMENT); compile options: {options:?}"
    );
}
