#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
command -v ucode >/dev/null || { echo '需要 ucode（可在路由器上运行此测试）'; exit 77; }
command -v jsonfilter >/dev/null || { echo '需要 jsonfilter'; exit 77; }
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT INT TERM
cat > "$work/proxies.json" <<'EOF'
{"proxies":{
 "PROXY":{"type":"Selector","all":["AUTO","HK \"A\"/中文😀","empty-history","DIRECT","NO-SUBSCRIPTION"],"now":"AUTO"},
 "AUTO":{"type":"URLTest","all":["HK \"A\"/中文😀","empty-history"],"now":"HK \"A\"/中文😀","alive":true},
 "HK \"A\"/中文😀":{"type":"Vless","history":[{"delay":123}],"alive":true,"server":"192.0.2.10","password":"fixture-private-value"},
 "empty-history":{"type":"Vmess","history":[],"alive":false},
 "DIRECT":{"type":"Direct"},"NO-SUBSCRIPTION":{"type":"Reject"},
 "outside":{"type":"Vless","history":[{"delay":10}]}
}}
EOF
ucode files/usr/lib/netpilot/nodes.uc list "$work/proxies.json" > "$work/list.json"
[ "$(jsonfilter -i "$work/list.json" -e '@.selected')" = AUTO ]
[ "$(jsonfilter -i "$work/list.json" -e '@.current')" = 'HK "A"/中文😀' ]
[ "$(jsonfilter -i "$work/list.json" -e '@.nodes[1].delay')" = 123 ]
[ "$(jsonfilter -i "$work/list.json" -e '@.nodes[2].alive')" = false ]
! grep -q 'fixture-private-value\|192.0.2.10\|NO-SUBSCRIPTION' "$work/list.json"
printf '%s' 'HK "A"/中文😀' > "$work/name"
ucode files/usr/lib/netpilot/nodes.uc request "$work/proxies.json" "$work/name" > "$work/request.json"
[ "$(jsonfilter -i "$work/request.json" -e '@.name')" = 'HK "A"/中文😀' ]
for rejected in DIRECT NO-SUBSCRIPTION outside missing; do
    printf '%s' "$rejected" > "$work/name"
    if ucode files/usr/lib/netpilot/nodes.uc request "$work/proxies.json" "$work/name" >/dev/null 2>&1; then
        echo "Unexpectedly allowed: $rejected"; exit 1
    fi
done
printf '%s' 'HK "A"/中文😀' > "$work/name"
if ucode files/usr/lib/netpilot/nodes.uc verify "$work/proxies.json" "$work/name" >/dev/null 2>&1; then
    echo 'Read-back verification should reject an unchanged selector'; exit 1
fi
echo 'PASS: node metadata, Unicode selection, allowlist and read-back verification'
