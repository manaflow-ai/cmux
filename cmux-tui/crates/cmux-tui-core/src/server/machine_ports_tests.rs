use super::*;

fn ports(table: &str) -> Vec<(u16, Option<String>)> {
    offered(table).into_iter().map(|l| (l.port, l.process)).collect()
}

fn named(port: u16, process: &str) -> (u16, Option<String>) {
    (port, Some(process.to_owned()))
}

#[test]
fn ss_names_the_dev_server_and_drops_system_and_ephemeral_ports() {
    let table = "\
LISTEN 0      511        127.0.0.1:5173       0.0.0.0:*    users:((\"node\",pid=4242,fd=23))
LISTEN 0      128          0.0.0.0:22         0.0.0.0:*    users:((\"sshd\",pid=1,fd=3))
LISTEN 0      4096   127.0.0.53%lo:53         0.0.0.0:*
LISTEN 0      511            [::1]:5173          [::]:*    users:((\"node\",pid=4242,fd=24))
LISTEN 0      128          0.0.0.0:41234      0.0.0.0:*
LISTEN 0      128                *:8080             *:*
";
    assert_eq!(ports(table), vec![named(5173, "node"), (8080, None)]);
}

#[test]
fn linux_netstat_reads_the_program_after_the_pid() {
    let table = "\
Active Internet connections (only servers)
Proto Recv-Q Send-Q Local Address           Foreign Address         State       PID/Program name
tcp        0      0 127.0.0.1:3000          0.0.0.0:*               LISTEN      901/node
tcp6       0      0 :::8000                 :::*                    LISTEN      -
tcp        0      0 0.0.0.0:631             0.0.0.0:*               LISTEN      -
";
    assert_eq!(ports(table), vec![named(3000, "node"), (8000, None)]);
}

#[test]
fn a_macs_lsof_keeps_the_persons_servers_not_airplay() {
    let table = "\
COMMAND     PID USER   FD   TYPE             DEVICE SIZE/OFF NODE NAME
ControlCe   612  leo    9u  IPv4 0x8f1c2e0d3c7a1b11      0t0  TCP *:7000 (LISTEN)
ControlCe   612  leo   10u  IPv6 0x8f1c2e0d3c7a1b12      0t0  TCP *:5000 (LISTEN)
rapportd    640  leo    4u  IPv4 0x8f1c2e0d3c7a1b13      0t0  TCP *:49157 (LISTEN)
node      90210  leo   21u  IPv6 0x8f1c2e0d3c7a1b14      0t0  TCP [::1]:5173 (LISTEN)
python3   90300  leo    3u  IPv4 0x8f1c2e0d3c7a1b15      0t0  TCP 127.0.0.1:8000 (LISTEN)
Code\\x20H 90400  leo    3u  IPv4 0x8f1c2e0d3c7a1b16      0t0  TCP 127.0.0.1:4000 (LISTEN)
";
    assert_eq!(
        ports(table),
        vec![named(4000, "Code H"), named(5173, "node"), named(8000, "python3")]
    );
}

#[test]
fn a_macs_netstat_reads_the_dotted_port() {
    let table = "\
Active Internet connections (including servers)
Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)
tcp4       0      0  127.0.0.1.5173         *.*                    LISTEN
tcp46      0      0  *.3000                 *.*                    LISTEN
tcp4       0      0  10.0.0.2.52011         17.57.146.10.5223      ESTABLISHED
";
    assert_eq!(ports(table), vec![(3000, None), (5173, None)]);
}

#[test]
fn a_port_is_offered_once_and_the_list_is_bounded() {
    let mut table = String::new();
    for port in 3000..3100u16 {
        table.push_str(&format!("LISTEN 0 1 127.0.0.1:{port} 0.0.0.0:*\n"));
        table.push_str(&format!("LISTEN 0 1 [::1]:{port} [::]:* users:((\"vite\",pid=1,fd=2))\n"));
    }
    let offered = offered(&table);
    assert_eq!(offered.len(), MAX_PORTS);
    assert_eq!(offered[0], Listener { port: 3000, process: Some("vite".into()) });
}

#[test]
fn an_empty_or_unknown_table_offers_nothing() {
    assert!(offered("").is_empty());
    assert!(offered("neither ss nor netstat\nState Recv-Q\n").is_empty());
}
