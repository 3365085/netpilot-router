#!/bin/sh
# Run on the router as root, from an extracted NetPilot release.
set -eu
cd "$(dirname "$0")"
[ "$(id -u)" = 0 ] || { echo '请以 root 安装'; exit 1; }
for cmd in curl nft ip dnsmasq jsonfilter uci ucode sha256sum; do
    command -v "$cmd" >/dev/null || { echo "缺少依赖：$cmd"; exit 1; }
done
ucode -e 'import { readfile } from "fs";' >/dev/null 2>&1 || { echo '缺少依赖：ucode-mod-fs'; exit 1; }
[ -x /usr/bin/mihomo ] || { echo '请先安装官方 Mihomo 核心到 /usr/bin/mihomo，然后重新运行安装。'; exit 1; }
/usr/bin/mihomo -v >/dev/null || exit 1
stamp=$(date +%Y%m%d-%H%M%S)
backup="/root/netpilot-backup-$stamp"
mkdir -p "$backup"
chmod 700 "$backup"
for path in /etc/allinone /etc/init.d/allinone /www/cgi-bin/netmode /www/net.html /www/netpilot.html /www/netpilot-diagnostic.html /usr/lib/netpilot /usr/share/netpilot /usr/sbin/netpilot-rebuild /usr/sbin/netpilot-firewall /usr/sbin/netpilot-nodes /usr/sbin/netpilot-connections /usr/sbin/netpilot-tun /usr/sbin/netpilot-watch /etc/config/firewall /etc/config/uhttpd /etc/httpd.conf; do
    if [ -e "$path" ]; then
        mkdir -p "$backup$(dirname "$path")"
        cp -a "$path" "$backup$path"
    fi
done
cp -R files/. /
chmod 755 /etc/init.d/allinone /etc/hotplug.d/dhcp/99-netmode /www/cgi-bin/netmode /usr/sbin/netpilot-rebuild /usr/sbin/netpilot-firewall /usr/sbin/netpilot-nodes /usr/sbin/netpilot-connections /usr/sbin/netpilot-tun /usr/sbin/netpilot-watch
chmod 644 /www/netpilot.html /www/netpilot-diagnostic.html /usr/share/netpilot/base.yaml /usr/lib/netpilot/config.sh
ln -sf netmode /www/cgi-bin/netpilot
cat > /www/net.html <<'EOF'
<!doctype html><html lang="zh-CN"><meta charset="utf-8"><meta http-equiv="refresh" content="0;url=/netpilot.html"><title>NetPilot 网络助手</title><a href="/netpilot.html">打开 NetPilot 网络助手</a></html>
EOF
mkdir -p /etc/allinone/proxy_providers /etc/allinone/rule_providers
chmod 700 /etc/allinone
touch /etc/allinone/peers.conf /etc/allinone/clash_profiles.conf
if [ ! -s /etc/allinone/adg_sources.conf ]; then
    cat > /etc/allinone/adg_sources.conf <<'EOF'
adg_awavenue|秋风广告规则 AWAvenue|http|yaml|https://gcore.jsdelivr.net/gh/TG-Twilight/AWAvenue-Ads-Rule@main/Filters/AWAvenue-Ads-Rule-Clash.yaml|1
adg_hagezi_light|HaGeZi Light|http|text|https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/light-onlydomains.txt|1
EOF
fi
chmod 600 /etc/allinone/*.conf
# Protect subscriptions and all mode changes with the router password. $p$root
# asks uhttpd to check the existing system password; no password is copied here.
touch /etc/httpd.conf
for route in /cgi-bin/netmode /cgi-bin/netpilot /net.html /netpilot.html /netpilot-diagnostic.html; do
    grep -Fq "$route:" /etc/httpd.conf || printf '%s:root:$p$root\n' "$route" >> /etc/httpd.conf
done
uci set uhttpd.main.config=/etc/httpd.conf
uci commit uhttpd
uci set firewall.netpilot=include
uci set firewall.netpilot.type=script
uci set firewall.netpilot.path=/usr/sbin/netpilot-firewall
uci set firewall.netpilot.fw4_compatible=1
# Only TUN return traffic can enter this zone; allow it back to LAN clients.
uci set firewall.netpilot_tun=zone
uci set firewall.netpilot_tun.name=netpilot_tun
uci set firewall.netpilot_tun.input=REJECT
uci set firewall.netpilot_tun.output=ACCEPT
uci set firewall.netpilot_tun.forward=REJECT
uci -q delete firewall.netpilot_tun.device || true
for dev in npt-cr npt-br npt-cg npt-bg; do uci add_list firewall.netpilot_tun.device="$dev"; done
uci set firewall.netpilot_tun_lan=forwarding
uci set firewall.netpilot_tun_lan.src=netpilot_tun
uci set firewall.netpilot_tun_lan.dest=lan
# Hardware bypass and flow offload can retain an earlier per-device decision.
uci set firewall.@defaults[0].flow_offloading=0
uci set firewall.@defaults[0].flow_offloading_hw=0
uci commit firewall
mkdir -p /etc/crontabs
touch /etc/crontabs/root
if ! grep -q 'netpilot-rebuild' /etc/crontabs/root; then
    echo '23 4 * * * /usr/sbin/netpilot-rebuild --apply >/dev/null 2>&1' >> /etc/crontabs/root
fi
/etc/init.d/cron reload || true
/etc/init.d/uhttpd restart
/etc/init.d/firewall reload
if ! /usr/sbin/netpilot-rebuild; then
    echo "配置检查失败；安装前备份位于 $backup。修正规则源后运行 netpilot-rebuild --apply。"
    exit 1
fi
/etc/init.d/allinone enable
if [ -x /etc/init.d/allinone ]; then /etc/init.d/allinone stop || true; fi
NETPILOT_SKIP_COMPILE=1 /etc/init.d/allinone start
echo "NetPilot 已安装。打开 http://路由器IPv4地址/netpilot.html ，使用 root 和路由器密码登录。备份：$backup"
