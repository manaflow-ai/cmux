//! Terminal prompts (readline equivalents). Blocking stdin reads run on the
//! blocking pool so ceremony sockets stay serviced.

use std::io::Write as _;

pub async fn prompt_line(question: &str) -> String {
    let question = question.to_owned();
    tokio::task::spawn_blocking(move || {
        print!("{question}");
        let _ = std::io::stdout().flush();
        let mut line = String::new();
        let _ = std::io::stdin().read_line(&mut line);
        line.trim_end_matches(['\n', '\r']).to_owned()
    })
    .await
    .unwrap_or_default()
}

pub async fn ask(question: &str) -> bool {
    let answer = prompt_line(&format!("{question} [y/N] ")).await;
    let answer = answer.trim().to_ascii_lowercase();
    answer == "y" || answer == "yes"
}
