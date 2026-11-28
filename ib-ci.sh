set -e
cd cmux-tui
cargo test -p acpmux --lib -- hub::inbox 2>&1 | grep -vE "cm[ej]_|ghs_|ghp_|xox" | tail -40
cargo test -p acpmux --lib -- ten_thousand --nocapture 2>&1 | grep -E "INBOX10K|test result" 
# baseline: the old inbox code with the same bench
F=crates/acpmux/src
git checkout 6394b4ec8af39d81a34bbacef18ab4d2da772f2d -- $F/hub/inbox.rs $F/hub/inbox_surge.rs $F/server/requests.rs $F/hub/inbox_tests.rs
rm -f $F/hub/inbox_fold.rs
cat ../ib-bench-before.rs >> $F/hub/inbox_tests.rs
cargo test -p acpmux --lib -- inbox_ten_k_before --nocapture 2>&1 | grep -E "INBOX10K|test result|error" | head
