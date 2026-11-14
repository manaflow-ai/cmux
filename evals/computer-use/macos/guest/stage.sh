# stage.sh: rebuild the fixture on the mini and push fixture + matrix into a guest (VM name arg)
set -e
vm=${1:-truth-1}
cd ~/truth-evals && rm -rf stage && mkdir stage && tar xzf truth-stage.tgz -C stage
(cd stage/fixtures/macos && DEVELOPER_DIR=/Applications/Xcode_26.6.app/Contents/Developer ./build.sh ~/truth-evals/fixture-build 2>&1 | grep -E "error|warning" || true)
tar czf fix.tgz -C ~/truth-evals fixture-build
./gcp.sh $vm truth-stage.tgz /tmp/truth-stage.tgz
./gcp.sh $vm fix.tgz /tmp/fix.tgz
./gs.sh $vm "mkdir -p ~/cu/truth && tar xzf /tmp/truth-stage.tgz -C ~/cu/truth && cp -R ~/cu/truth/macos/* ~/cu/truth/ && rm -rf ~/cu/fixture-build && tar xzf /tmp/fix.tgz -C ~/cu && xattr -dr com.apple.quarantine ~/cu/fixture-build; echo staged"
