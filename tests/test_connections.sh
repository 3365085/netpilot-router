#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
command -v ucode >/dev/null || exit 77
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM
cat > "$work/state.json" <<'EOF'
{"connections":[
 {"id":"00000000-0000-4000-8000-000000000001","metadata":{"sourceIP":"192.0.2.10","password":"fixture-private"}},
 {"id":"00000000-0000-4000-8000-000000000002","metadata":{"sourceIP":"::ffff:192.0.2.10"}},
 {"id":"00000000-0000-4000-8000-000000000003","metadata":{"sourceIP":"192.0.2.11"}},
 {"id":"00000000-0000-4000-8000-000000000004","metadata":{"sourceIP":""}},
 {"id":"00000000-0000-4000-8000-000000000001","metadata":{"sourceIP":"192.0.2.10"}}
]}
EOF
ucode files/usr/lib/netpilot/connections.uc "$work/state.json" 192.0.2.10 > "$work/actual"
printf '%s\n' 00000000-0000-4000-8000-000000000001 00000000-0000-4000-8000-000000000002 > "$work/expected"
cmp "$work/expected" "$work/actual"
! grep -q 'fixture-private\|000000000003\|000000000004' "$work/actual"
printf '{"connections":null}\n' > "$work/empty.json"
[ -z "$(ucode files/usr/lib/netpilot/connections.uc "$work/empty.json" 192.0.2.10)" ]
for invalid in '' 999.0.0.1 192.0.2.10/24 '192.0.2.10;false'; do
    if ucode files/usr/lib/netpilot/connections.uc "$work/state.json" "$invalid" >/dev/null 2>&1; then
        echo 'Invalid source address accepted'; exit 1
    fi
done
printf '{"connections":[{"id":"../all","metadata":{"sourceIP":"192.0.2.10"}}]}\n' > "$work/invalid.json"
if ucode files/usr/lib/netpilot/connections.uc "$work/invalid.json" 192.0.2.10 >/dev/null 2>&1; then
    echo 'Invalid connection ID accepted'; exit 1
fi
printf '{"connections":"invalid"}\n' > "$work/invalid.json"
if ucode files/usr/lib/netpilot/connections.uc "$work/invalid.json" 192.0.2.10 >/dev/null 2>&1; then
    echo 'Malformed connection snapshot accepted'; exit 1
fi
printf '{}\n' > "$work/invalid.json"
if ucode files/usr/lib/netpilot/connections.uc "$work/invalid.json" 192.0.2.10 >/dev/null 2>&1; then
    echo 'Missing connection list accepted'; exit 1
fi
echo 'PASS: client isolation, mapped IPv4, deduplication, empty list and invalid input'
