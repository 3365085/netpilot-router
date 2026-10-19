#!/bin/sh
# Run as root on the router, with a cross-compiled tests/udp_probe.go binary.
# Creates only a disposable LAN client. --fault-tests also restarts the live core.
set -eu
PROBE="${1:?用法: sh router_transport.sh /tmp/udp-probe [--fault-tests]}"
FAULTS="${2:-}"
[ "$(id -u)" = 0 ] && [ "$(cat /etc/allinone/backend)" = tc-tun ] || exit 77
[ -x "$PROBE" ] || exit 77
NS=npt-transport
LINK=npt-test-host
PEER=npt-test-peer
IP=192.168.9.250
MAC=02:00:00:09:02:50
LAN=$(ubus call network.interface.lan status | jsonfilter -e '@.l3_device')
work=$(mktemp -d /tmp/netpilot-transport.XXXXXX)
chmod 700 "$work"
stopped=0
created=0
cleanup() {
    if [ "$stopped" = 1 ]; then NETPILOT_SKIP_COMPILE=1 /etc/init.d/allinone start >/dev/null 2>&1 || true; fi
    if [ "$created" = 1 ]; then
        awk -F'|' -v m="$MAC" '$1!=m' /etc/allinone/peers.conf > "$work/peers"
        cat "$work/peers" > /etc/allinone/peers.conf
        /etc/init.d/allinone reload >/dev/null 2>&1 || true
        ip netns del "$NS" 2>/dev/null || true
        ip link del "$LINK" 2>/dev/null || true
        rm -rf "/etc/netns/$NS"
    fi
    rm -rf "$work"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
if ip link show "$LINK" >/dev/null 2>&1 || ip netns list | grep -q "^$NS "; then echo '测试命名空间已存在'; exit 1; fi
if grep -q "$IP\|$MAC" /etc/allinone/peers.conf /tmp/dhcp.leases; then echo '测试地址已被使用'; exit 1; fi
cp /etc/allinone/peers.conf "$work/other-peers"
ip netns add "$NS"
created=1
ip link add "$LINK" type veth peer name "$PEER"
ip link set "$PEER" netns "$NS"
ip link set "$LINK" master "$LAN"
ip link set "$LINK" up
ip netns exec "$NS" ip link set lo up
ip netns exec "$NS" ip link set "$PEER" address "$MAC"
ip netns exec "$NS" ip addr add "$IP/24" dev "$PEER"
ip netns exec "$NS" ip link set "$PEER" up
ip netns exec "$NS" ip route add default via 192.168.9.1
mkdir -p "/etc/netns/$NS"
echo 'nameserver 192.168.9.1' > "/etc/netns/$NS/resolv.conf"

client() { ip netns exec "$NS" "$@"; }
mode() {
    QUERY_STRING="mode=$1&routing=$2" REQUEST_METHOD=POST REMOTE_ADDR="$IP" HTTP_HOST=192.168.9.1 \
        /www/cgi-bin/netmode | sed -n '/^{/,$p' > "$work/status.json"
    [ "$(jsonfilter -i "$work/status.json" -e '@.ok')" = true ]
    [ "$(jsonfilter -i "$work/status.json" -e '@.mode')" = "$1" ]
    [ "$(jsonfilter -i "$work/status.json" -e '@.routing')" = "$2" ]
    [ "$(jsonfilter -i "$work/status.json" -e '@.tun_ready')" = true ]
}
tcp_ip() { client curl --noproxy '*' -4 -fsS --resolve "api.ipify.org:443:$IPIFY_ADDR" --connect-timeout 3 --max-time "${1:-10}" https://api.ipify.org; }
udp_ip() {
    client "$PROBE" "$1" > "$work/stun.json"
    [ "$(jsonfilter -i "$work/stun.json" -e '@.ok')" = true ]
    jsonfilter -i "$work/stun.json" -e '@.mapped_ip'
}
dns_blocked() {
    client nslookup "$1" 192.168.9.1 > "$work/dns" 2>&1 || true
    grep -q NXDOMAIN "$work/dns"
}
healthy() {
    local n=0
    until /usr/sbin/netpilot-tun check >/dev/null 2>&1 && curl -fsS --max-time 1 http://127.0.0.1:9090/version >/dev/null 2>&1; do
        n=$((n+1)); [ "$n" -lt 25 ] || return 1; sleep 1
    done
}

# Populate ARP before exercising the actual CGI device identity path.
client curl --noproxy '*' -s --max-time 3 http://192.168.9.1/net.html -o /dev/null
direct=$(udp_ip 162.159.207.0:3478)
mode both global
IPIFY_ADDR=$(client nslookup api.ipify.org 192.168.9.1 | awk '$1=="Address:" && $2 ~ /^[0-9.]+$/ {print $2; exit}')
[ -n "$IPIFY_ADDR" ]
proxy_tcp=$(tcp_ip)
proxy_udp=$(udp_ip 162.159.207.0:3478)
[ -n "$proxy_tcp" ] && [ "$proxy_tcp" = "$proxy_udp" ] && [ "$proxy_tcp" != "$direct" ]
[ "$(udp_ip 74.125.250.129:19302)" = "$proxy_udp" ]
echo '{"check":"tcp_udp_proxy_egress","ok":true,"stun_services":2,"same_exit":true,"different_from_direct":true}'
for domain in ad.doubleclick.net pagead2.googlesyndication.com mi.gdt.qq.com mobads.baidu.com; do dns_blocked "$domain"; done
for site in https://www.baidu.com/ https://www.jd.com/ https://www.apple.com/; do
    client curl --noproxy '*' -4 -fsS -o /dev/null --connect-timeout 5 --max-time 15 "$site"
done
echo '{"check":"filtering_and_normal_sites","ok":true,"ad_domains":4,"normal_https_sites":3}'
qq_direct=$(curl --noproxy '*' -4 -sS --connect-timeout 4 --max-time 10 -o /dev/null -w '%{http_code}' https://www.qq.com/)
qq_filtered=$(client curl --noproxy '*' -4 -sS --connect-timeout 4 --max-time 10 -o /dev/null -w '%{http_code}' https://www.qq.com/)
[ "$qq_direct" = "$qq_filtered" ]
printf '{"check":"qq_waf_control","ok":true,"direct_http":%s,"filtered_http":%s}\n' "$qq_direct" "$qq_filtered"
mode adg rule
[ "$(udp_ip 162.159.207.0:3478)" = "$direct" ]
dns_blocked ad.doubleclick.net
mode clash global
client nslookup ad.doubleclick.net 192.168.9.1 > "$work/dns" 2>&1
! grep -q NXDOMAIN "$work/dns"
AD_ADDR=$(awk '$1=="Address:" && $2 ~ /^[0-9.]+$/ {print $2; exit}' "$work/dns")
[ -n "$AD_ADDR" ]
# Identical numeric destination + TLS SNI, independent of filtered DNS/cache.
client curl --noproxy '*' -4 -sS --connect-timeout 3 --max-time 8 \
    --resolve "ad.doubleclick.net:443:$AD_ADDR" -o /dev/null https://ad.doubleclick.net/
[ "$(udp_ip 162.159.207.0:3478)" = "$proxy_udp" ]
mode both rule
[ "$(udp_ip 162.159.207.0:3478)" = "$proxy_udp" ]
mode both global
if client curl --noproxy '*' -4 -sS --connect-timeout 3 --max-time 8 \
    --resolve "ad.doubleclick.net:443:$AD_ADDR" -o /dev/null https://ad.doubleclick.net/ 2>/dev/null; then
    echo '组合模式未阻断广告 TLS 请求'; exit 1
fi
echo '{"check":"tls_filter_without_dns","ok":true,"allowed_in_proxy_mode":true,"blocked_in_combined_mode":true}'
awk -F'|' -v m="$MAC" '$1!=m' /etc/allinone/peers.conf > "$work/other-after"
cmp "$work/other-peers" "$work/other-after"
echo '{"check":"device_mode_isolation","ok":true,"modes":["both/global","adg/rule","clash/global","both/rule"],"other_devices_unchanged":true}'

# A failed staged TC update must retain the active dispatcher and chain.
mkdir "$work/state" "$work/config"
echo "$MAC|$IP|both|global|test" > "$work/config/peers.conf"
NETMODE_CONF_DIR="$work/config" NETPILOT_TUN_STATE="$work/state" NETPILOT_LAN_DEVICE="$LINK" /usr/sbin/netpilot-tun sync
tc -j filter show dev "$LINK" ingress chain 0 > "$work/dispatcher-before"
echo "$MAC|999.1.1.1|both|global|invalid" > "$work/config/peers.conf"
if NETMODE_CONF_DIR="$work/config" NETPILOT_TUN_STATE="$work/state" NETPILOT_LAN_DEVICE="$LINK" /usr/sbin/netpilot-tun sync; then exit 1; fi
tc -j filter show dev "$LINK" ingress chain 0 > "$work/dispatcher-after"
cmp "$work/dispatcher-before" "$work/dispatcher-after"
NETMODE_CONF_DIR="$work/config" NETPILOT_TUN_STATE="$work/state" NETPILOT_LAN_DEVICE="$LINK" /usr/sbin/netpilot-tun remove
echo '{"check":"tc_staging_failure","ok":true,"previous_dispatcher_preserved":true}'

if [ "$FAULTS" = --fault-tests ]; then
    pid=$(ubus call service list '{"name":"allinone"}' | jsonfilter -e '@.allinone.instances.mihomo.pid')
    [ -n "$pid" ]
    kill -9 "$pid"
    failures=0; successes=0
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
        if result=$(tcp_ip 2 2>/dev/null); then
            [ "$result" = "$proxy_tcp" ] || { echo '异常恢复期间发现不同出口'; exit 1; }
            successes=$((successes+1))
        else failures=$((failures+1)); fi
        sleep 1
    done
    healthy
    [ "$failures" -gt 0 ] && [ "$(udp_ip 162.159.207.0:3478)" = "$proxy_udp" ]
    printf '{"check":"core_crash_recovery","ok":true,"blocked_samples":%s,"proxy_samples":%s,"direct_samples":0}\n' "$failures" "$successes"
    /etc/init.d/allinone stop >/dev/null
    stopped=1
    if tcp_ip >/dev/null 2>&1; then echo '核心停止后 TCP 发生旁路'; exit 1; fi
    if udp_ip 162.159.207.0:3478 >/dev/null 2>&1; then echo '核心停止后 UDP 发生旁路'; exit 1; fi
    nft list table inet netmode >/dev/null
    NETPILOT_SKIP_COMPILE=1 /etc/init.d/allinone start >/dev/null
    stopped=0
    healthy
    [ "$(tcp_ip)" = "$proxy_tcp" ] && [ "$(udp_ip 162.159.207.0:3478)" = "$proxy_udp" ]
    echo '{"check":"service_stop_start","ok":true,"tcp_blocked_while_stopped":true,"udp_blocked_while_stopped":true,"recovered":true}'
fi
echo '{"check":"complete","ok":true}'
