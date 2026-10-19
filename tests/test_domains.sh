#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_tmp=$(mktemp -d)
trap 'rm -rf "$task_tmp"' EXIT
cat > "$task_tmp/input" <<'EOF'
# comment
payload:
  - 'ads.example.com'
  - "+.Tracker.Example.net"
  - '*.metrics.example.org'
0.0.0.0 host.example.com
||abp.example.com^
||context.example.com^$third-party
@@||allowed.example.com^
example.com##.banner
0.0.0.0 localhost
127.0.0.1
http://invalid.example.com/path
EOF
. files/usr/lib/netpilot/config.sh
netpilot_domains "$task_tmp/input" > "$task_tmp/actual"
cat > "$task_tmp/expected" <<'EOF'
+.abp.example.com
+.ads.example.com
+.host.example.com
+.metrics.example.org
+.tracker.example.net
EOF
diff -u "$task_tmp/expected" "$task_tmp/actual"
for script in install.sh files/etc/init.d/allinone files/usr/lib/netpilot/config.sh files/usr/sbin/netpilot-rebuild files/usr/sbin/netpilot-firewall files/usr/sbin/netpilot-nodes files/usr/sbin/netpilot-connections files/usr/sbin/netpilot-tun files/usr/sbin/netpilot-watch files/www/cgi-bin/netmode; do
    sh -n "$script"
done
printf 'PASS: domain normalization and shell syntax\n'
