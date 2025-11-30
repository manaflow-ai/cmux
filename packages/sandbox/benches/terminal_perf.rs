use std::sync::OnceLock;

use cmux_sandbox::mux::terminal::TerminalBuffer;
use criterion::{black_box, criterion_group, criterion_main, BatchSize, Criterion};

fn sample_colored_output() -> &'static Vec<u8> {
    static DATA: OnceLock<Vec<u8>> = OnceLock::new();
    DATA.get_or_init(|| {
        let mut lines = String::new();
        for i in 0..2000 {
            lines.push_str(&format!(
                "\x1b[38;5;42mINFO\x1b[0m [{:04}] building target crate{}\x1b[0m at /workspace/src/bin/task{:04}.rs\n",
                i,
                i % 17,
                i % 250
            ));
        }
        lines.into_bytes()
    })
}

fn bench_process_colored_chunks(c: &mut Criterion) {
    let data = sample_colored_output();
    let chunks: Vec<&[u8]> = data.chunks(512).collect();

    c.bench_function("process_colored_chunks", |b| {
        b.iter_batched(
            || TerminalBuffer::with_size(40, 120),
            |mut buffer| {
                for chunk in &chunks {
                    buffer.process(black_box(chunk));
                }
            },
            BatchSize::SmallInput,
        );
    });
}

fn bench_render_visible_lines(c: &mut Criterion) {
    let data = sample_colored_output();
    let mut buffer = TerminalBuffer::with_size(40, 120);
    buffer.process(data);

    c.bench_function("render_visible_lines_height_30", |b| {
        b.iter(|| {
            let view = buffer.render_view(30);
            black_box(view.lines.to_vec());
        });
    });
}

criterion_group!(
    terminal_benches,
    bench_process_colored_chunks,
    bench_render_visible_lines
);
criterion_main!(terminal_benches);
