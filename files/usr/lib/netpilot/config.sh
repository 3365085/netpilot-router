#!/bin/sh
# Shared configuration compiler. Runtime data stays in the legacy directory so
# upgrades preserve existing subscriptions and per-device choices.
CONF_DIR="${NETMODE_CONF_DIR:-/etc/allinone}"
CONF_FILE="$CONF_DIR/config.yaml"
CLASH_LIST_FILE="$CONF_DIR/clash_profiles.conf"
ADG_LIST_FILE="$CONF_DIR/adg_sources.conf"
BASE_FILE="${NETPILOT_BASE_FILE:-/usr/share/netpilot/base.yaml}"

netpilot_backend() {
    if ip -4 rule show >/dev/null 2>&1; then
        echo tproxy
    elif /usr/bin/mihomo -v 2>/dev/null | grep -q with_gvisor && /usr/sbin/netpilot-tun probe >/dev/null 2>&1; then
        echo tc-tun
    else
        echo redirect
    fi
}

netpilot_domains() {
    # Accept domain payload YAML, plain domain lists, hosts and simple DNS ABP
    # rules. Context-dependent AdBlock/cosmetic/exception rules are not converted.
    awk '
    {
        gsub(/\r/, ""); sub(/^[ \t]+/, ""); sub(/[ \t]+$/, "")
        if ($0 == "" || /^[!#\[]/ || /^@@/ || /^payload:/) next
        sub(/^-[ \t]+/, "")
        gsub(/^[\047\042]|[\047\042]$/, "")
        if ($1 == "0.0.0.0" || $1 == "127.0.0.1") $0=$2
        if (/^\|\|[a-zA-Z0-9._-]+\^$/) { sub(/^\|\|/, ""); sub(/\^$/, "") }
        sub(/^\+\./, ""); sub(/^\*\./, ""); sub(/^\./, "")
        if (/^[a-zA-Z0-9_-]+(\.[a-zA-Z0-9_-]+)+$/ && !/^[0-9.]+$/) print "+." tolower($0)
    }' "$1" | sort -u
}

netpilot_compile() {
    local backend="${NETPILOT_BACKEND:-$(netpilot_backend)}"
    local work="$CONF_DIR/.compile.$$"
    local ids="" id name kind fmt value enabled raw cache count
    local cid="" ckind="" cvalue="" cname="" active=""
    mkdir -p "$CONF_DIR/proxy_providers" "$CONF_DIR/rule_providers" "$work" || return 1
    chmod 700 "$CONF_DIR" "$work"
    : > "$work/adblock.dnsmasq"
    : > "$work/adg-providers"

    if [ -f "$ADG_LIST_FILE" ]; then
        while IFS='|' read -r id name kind fmt value enabled; do
            [ "$enabled" = 1 ] || continue
            case "$id" in ''|*[!a-zA-Z0-9_-]*) echo '无效的广告规则 ID' >&2; rm -rf "$work"; return 1 ;; esac
            case "$fmt" in yaml|text) ;; *) echo 'DNS 拦截需要 domain YAML 或域名文本，请更换 MRS/其他格式' >&2; rm -rf "$work"; return 1 ;; esac
            cache="$CONF_DIR/rule_providers/$id.source"
            raw="$work/$id.source"
            if [ "$kind" = http ]; then
                case "$value" in http://*|https://*) ;; *) echo '规则地址需要 HTTP(S)' >&2; rm -rf "$work"; return 1 ;; esac
                # Do not put private URLs in logs or use third-party converters.
                if ! curl -fsSL --connect-timeout 5 --max-time 25 "$value" -o "$raw" 2>/dev/null; then
                    if [ -s "$cache" ]; then cp "$cache" "$raw"; else echo "规则源 $id 下载失败" >&2; rm -rf "$work"; return 1; fi
                fi
            else
                case "$value" in ./rule_providers/*) cp "$CONF_DIR/${value#./}" "$raw" || { rm -rf "$work"; return 1; } ;; *) echo '无效的本地规则路径' >&2; rm -rf "$work"; return 1 ;; esac
            fi
            netpilot_domains "$raw" > "$work/$id.txt"
            count=$(wc -l < "$work/$id.txt")
            if [ "$count" -lt 1 ]; then echo "规则源 $id 不包含可用的 DNS 域名规则" >&2; rm -rf "$work"; return 1; fi
            # The same normalized list drives DNS and Mihomo domain rejection.
            awk '{sub(/^\+\./, ""); print "address=/" $0 "/"}' "$work/$id.txt" >> "$work/adblock.dnsmasq"
            cat >> "$work/adg-providers" <<EOF
  $id:
    type: file
    behavior: domain
    format: text
    path: ./rule_providers/$id.txt
EOF
            ids="$ids $id"
        done < "$ADG_LIST_FILE"
    fi
    sort -u "$work/adblock.dnsmasq" > "$work/adblock.sorted"
    mv "$work/adblock.sorted" "$work/adblock.dnsmasq"

    if [ -s "$CLASH_LIST_FILE" ]; then
        local line
        line=$(awk -F'|' 'NF>=5 && $5==1 {print; exit}' "$CLASH_LIST_FILE")
        [ -n "$line" ] || line=$(awk -F'|' 'NF>=5 {print; exit}' "$CLASH_LIST_FILE")
        IFS='|' read -r cid cname ckind cvalue active <<EOF
$line
EOF
        case "$cid" in ''|*[!a-zA-Z0-9_-]*) echo '无效的代理配置 ID' >&2; rm -rf "$work"; return 1 ;; esac
    fi
    local listener=redir udp='# TCP compatibility mode'
    if [ "$backend" = tproxy ]; then listener=tproxy; udp='udp: true'; fi
    if [ "$backend" = tc-tun ]; then
        sed '/^listeners:/,$d' "$BASE_FILE" > "$work/config.yaml"
        cat "${NETPILOT_TUN_FILE:-/usr/share/netpilot/tun.yaml}" >> "$work/config.yaml"
    else
        sed -e "s/@BACKEND@/$listener/g" -e "s/@UDP@/$udp/g" "$BASE_FILE" > "$work/config.yaml"
    fi
    if [ -n "$cid" ]; then
        cat >> "$work/config.yaml" <<EOF
proxy-providers:
  airport:
    type: $ckind
EOF
        if [ "$ckind" = http ]; then
            case "$cvalue" in http://*|https://*) ;; *) echo '订阅地址需要 HTTP(S)' >&2; rm -rf "$work"; return 1 ;; esac
            case "$cvalue" in *\"*|*\\*) echo '订阅地址含无效字符，请使用 URL 编码' >&2; rm -rf "$work"; return 1 ;; esac
            cat >> "$work/config.yaml" <<EOF
    url: "$cvalue"
    proxy: DIRECT
    interval: 86400
    path: ./proxy_providers/$cid.yaml
EOF
        else
            case "$cvalue" in ./proxy_providers/*) ;; *) echo '无效的代理文件路径' >&2; rm -rf "$work"; return 1 ;; esac
            echo "    path: $cvalue" >> "$work/config.yaml"
        fi
        cat >> "$work/config.yaml" <<'EOF'
    override:
      udp: true
    health-check:
      enable: true
      url: https://www.gstatic.com/generate_204
      interval: 300
      lazy: true
proxy-groups:
  - name: PROXY
    type: select
    proxies: [AUTO]
    use: [airport]
  - name: AUTO
    type: url-test
    use: [airport]
    url: https://www.gstatic.com/generate_204
    interval: 300
    tolerance: 50
    lazy: true
EOF
    else
        cat >> "$work/config.yaml" <<'EOF'
proxies:
  - name: NO-SUBSCRIPTION
    type: reject
proxy-groups:
  - name: PROXY
    type: select
    proxies: [NO-SUBSCRIPTION]
EOF
    fi
    echo 'rule-providers:' >> "$work/config.yaml"
    cat "$work/adg-providers" >> "$work/config.yaml"
    for id in private_domain cn_domain private_ip cn_ip; do
        local behavior=domain group=geosite remote="$id"
        case "$id" in *_ip) behavior=ipcidr; group=geoip ;; esac
        case "$id" in private_*) remote=private ;; cn_*) remote=cn ;; esac
        # Keep provider files already downloaded by the original installation.
        cat >> "$work/config.yaml" <<EOF
  $id:
    type: http
    behavior: $behavior
    format: mrs
    path: ./rule_providers/$id.mrs
    url: https://testingcf.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@meta/geo/$group/$remote.mrs
    proxy: DIRECT
    interval: 86400
EOF
    done
    echo 'sub-rules:' >> "$work/config.yaml"
    local mode aid
    for mode in adg clash-rule both-rule clash-global both-global; do
        echo "  mode-$mode:" >> "$work/config.yaml"
        case "$mode" in adg|both-*) for aid in $ids; do echo "    - RULE-SET,$aid,REJECT" >> "$work/config.yaml"; done ;; esac
        if [ "$mode" != adg ]; then
            cat >> "$work/config.yaml" <<'EOF'
    - RULE-SET,private_domain,DIRECT
    - RULE-SET,private_ip,DIRECT,no-resolve
EOF
            case "$mode" in *-rule) cat >> "$work/config.yaml" <<'EOF'
    - RULE-SET,cn_domain,DIRECT
    - RULE-SET,cn_ip,DIRECT,no-resolve
EOF
            ;; esac
            echo '    - MATCH,PROXY' >> "$work/config.yaml"
        else
            echo '    - MATCH,DIRECT' >> "$work/config.yaml"
        fi
    done
    cat >> "$work/config.yaml" <<'EOF'
rules:
  - SUB-RULE,(IN-NAME,in-adg),mode-adg
  - SUB-RULE,(IN-NAME,in-clash-rule),mode-clash-rule
  - SUB-RULE,(IN-NAME,in-both-rule),mode-both-rule
  - SUB-RULE,(IN-NAME,in-clash-global),mode-clash-global
  - SUB-RULE,(IN-NAME,in-both-global),mode-both-global
  - RULE-SET,private_domain,DIRECT
  - RULE-SET,private_ip,DIRECT,no-resolve
  - RULE-SET,cn_domain,DIRECT
  - RULE-SET,cn_ip,DIRECT,no-resolve
  - MATCH,PROXY
EOF
    # Stage rule files at the paths the config validator expects, then validate
    # before replacing a running config. Cache updates never delete working data.
    for aid in $ids; do
        cp "$work/$aid.txt" "$CONF_DIR/rule_providers/$aid.txt"
        cp "$work/$aid.source" "$CONF_DIR/rule_providers/$aid.source"
    done
    if ! /usr/bin/mihomo -t -d "$CONF_DIR" -f "$work/config.yaml" > "$work/check.log" 2>&1; then
        echo 'Mihomo 配置检查失败，原配置仍保留。请检查订阅文件或日志。' >&2
        logger -t netpilot 'Configuration validation failed; previous config retained'
        rm -rf "$work"; return 1
    fi
    /usr/sbin/dnsmasq --test --conf-file=/dev/null --conf-file="$work/adblock.dnsmasq" >/dev/null 2>&1 || { echo 'DNS 规则验证失败' >&2; rm -rf "$work"; return 1; }
    mv "$work/config.yaml" "$CONF_FILE"
    mv "$work/adblock.dnsmasq" "$CONF_DIR/adblock.dnsmasq"
    wc -l < "$CONF_DIR/adblock.dnsmasq" > "$CONF_DIR/adblock.count"
    echo "$backend" > "$CONF_DIR/backend"
    chmod 600 "$CONF_FILE" "$CLASH_LIST_FILE" "$ADG_LIST_FILE" "$CONF_DIR"/*.count "$CONF_DIR/backend" 2>/dev/null
    rm -rf "$work"
}
