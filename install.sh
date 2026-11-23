#!/usr/bin/env bash
# Gost tunnel installer, bugfixed, with the tunnel optimizer built in.
# Listen on this server and forward each port to the same port on Kharej.
# Does not use one giant ExecStart, does not write rc.local, does not alias over gost.
#
#   sudo bash gost-tunnel.sh
#   sudo bash gost-tunnel.sh --optimize
#   sudo bash gost-tunnel.sh --self-test
set -o pipefail

GOST_V3=3.3.3
GOST_V3_AMD64_SHA256=f4c1255dc892a7014c0ad6e5f1c3573108f7bea4403f04f21873406ab58aa666
GOST_V2=2.11.5
CONF_DIR=/etc/gost
UNIT_DIR=/etc/systemd/system
BIN=/usr/local/bin/gost
MENU_BIN=/usr/local/bin/gost-tunnel
SYSCTL_MAIN=/etc/sysctl.d/99-tunnel-optimize.conf
SYSCTL_PORTS=/etc/sysctl.d/98-gost-ports.conf
NET_SCRIPT=/usr/local/sbin/tunnel-net-tweaks.sh
NET_UNIT=/etc/systemd/system/tunnel-net-tweaks.service
CHAIN=TUNNEL_OPT
CHUNK=1500
NOFILE=1048576

R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; B=$'\e[1m'; N=$'\e[0m'
info(){ printf '%s➜%s %s\n' "$C" "$N" "$*"; }
ok(){ printf '%s✔%s %s\n' "$G" "$N" "$*"; }
warn(){ printf '%s!%s %s\n' "$Y" "$N" "$*"; }
die(){ printf '%s✖%s %s\n' "$R" "$N" "$*" >&2; exit 1; }

need_root(){ [ "$(id -u)" -eq 0 ] || die "با root اجرا کن: sudo bash gost-tunnel.sh"; }

cpu_arch(){
    case "$(uname -m)" in
        x86_64|amd64) echo amd64 ;;
        aarch64|arm64) echo arm64 ;;
        armv7l) echo armv7 ;;
        i386|i686) echo 386 ;;
        *) die "معماری $(uname -m) پشتیبانی نمی‌شود." ;;
    esac
}

is_ipv4(){
    local ip=$1 o
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS=. read -r o1 o2 o3 o4 <<<"$ip"
    for o in "$o1" "$o2" "$o3" "$o4"; do
        [ "$o" -le 255 ] 2>/dev/null || return 1
    done
    return 0
}

is_ipv6(){
    [[ "$1" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
    [[ "$1" == *:* ]] || return 1
    [[ "$1" != *[^0-9A-Fa-f:]* ]] || return 1
    local c=${1//[^:]/}
    [ "${#c}" -ge 2 ] && [ "${#c}" -le 7 ]
}

dest_host(){
    # $1 = ip, prints the host:port host part
    if is_ipv4 "$1"; then printf '%s' "$1"
    elif is_ipv6 "$1"; then printf '[%s]' "$1"
    else return 1
    fi
}

ask_ip(){
    local kind=$1 ip
    while true; do
        if [ "$kind" = 6 ]; then
            read -r -p $'\e[97mآی‌پی نسخه ۶ خارج: \e[0m' ip
            is_ipv6 "$ip" && { printf '%s' "$ip"; return 0; }
            warn "IPv6 معتبر نیست."
        else
            read -r -p $'\e[97mآی‌پی نسخه ۴ خارج: \e[0m' ip
            is_ipv4 "$ip" && { printf '%s' "$ip"; return 0; }
            warn "IPv4 معتبر نیست."
        fi
    done
}

ask_proto(){
    local p
    echo "پروتکل:"
    echo "  1) TCP   برای Reality / VLESS / Trojan"
    echo "  2) UDP   برای Hysteria / TUIC"
    echo "  3) gRPC  فقط اگر کلاینت هم Gost باشد، نه کلاینت عادی"
    read -r -p "انتخاب [1]: " p
    case "${p:-1}" in
        1|tcp|TCP) echo tcp ;;
        2|udp|UDP) echo udp ;;
        3|grpc|GRPC) echo grpc ;;
        *) die "پروتکل نامعتبر." ;;
    esac
}

# Fills STARTS ENDS arrays. Accepts 443,2053 and 1000-20000.
# range_mode=1 treats "1000,20000" as a range, like the old script.
parse_port_spec(){
    local spec=$1 range_mode=$2 part a b
    STARTS=()
    ENDS=()
    spec=${spec// /}
    [ -n "$spec" ] || return 1
    if [ "$range_mode" = 1 ] && [[ "$spec" =~ ^([0-9]+),([0-9]+)$ ]]; then
        spec="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}"
    fi
    IFS=',' read -ra parts <<<"$spec"
    for part in "${parts[@]}"; do
        [ -n "$part" ] || return 1
        if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            a=${BASH_REMATCH[1]}
            b=${BASH_REMATCH[2]}
        elif [[ "$part" =~ ^[0-9]+$ ]]; then
            a=$part
            b=$part
        else
            return 1
        fi
        [ "$a" -ge 1 ] && [ "$b" -le 65535 ] && [ "$a" -le "$b" ] || return 1
        STARTS+=("$a")
        ENDS+=("$b")
    done
    [ "${#STARTS[@]}" -gt 0 ]
}

port_count(){
    local i n=0
    for i in "${!STARTS[@]}"; do
        n=$(( n + ENDS[i] - STARTS[i] + 1 ))
    done
    echo "$n"
}

ask_ports(){
    local mode spec
    echo "پورت‌ها:"
    echo "  1) لیست، مثل 443,2053,8443"
    echo "  2) بازه، مثل 10000-40000   (شکل قدیمی 10000,40000 هم قبول است)"
    read -r -p "انتخاب [1]: " mode
    case "${mode:-1}" in
        1) read -r -p "پورت‌ها: " spec; parse_port_spec "$spec" 0 || die "لیست پورت نامعتبر است." ;;
        2) read -r -p "بازه: " spec; parse_port_spec "$spec" 1 || die "بازه پورت نامعتبر است. از ۱ تا ۶۵۵۳۵." ;;
        *) die "انتخاب نامعتبر." ;;
    esac
    local n
    n=$(port_count)
    [ "$n" -gt 0 ] || die "پورتی انتخاب نشد."
    if [ "$n" -gt 30000 ]; then
        warn "$n پورت خیلی زیاد است و رم می‌خورد."
        read -r -p "ادامه می‌دهی؟ [y/N] " yn
        [ "$yn" = "y" ] || [ "$yn" = "Y" ] || die "لغو شد."
    fi
    info "$n پورت ثبت می‌شود."
}

overlaps_used(){
    local s=$1 e=$2 id a b
    [ -f "$CONF_DIR/ports.used" ] || return 1
    while read -r id a b; do
        [ -n "${a:-}" ] || continue
        if [ "$s" -le "$b" ] && [ "$e" -ge "$a" ]; then
            warn "پورت ${s}-${e} با فوروارد ${id} (${a}-${b}) تداخل دارد."
            return 0
        fi
    done < "$CONF_DIR/ports.used"
    return 1
}

ensure_pkgs(){
    command -v curl >/dev/null 2>&1 && return 0
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq || true
        apt-get install -y -qq curl ca-certificates || die "curl نصب نشد."
    else
        die "curl نیست و apt هم پیدا نشد."
    fi
}

install_gost(){
    local major=$1 arch url tmp bin
    ensure_pkgs
    arch=$(cpu_arch)
    tmp=$(mktemp -d)
    if [ "$major" = 2 ]; then
        local g
        case "$arch" in
            amd64) g=amd64 ;;
            arm64) g=armv8 ;;
            armv7) g=armv7 ;;
            386) g=386 ;;
        esac
        url="https://github.com/ginuerzh/gost/releases/download/v${GOST_V2}/gost-linux-${g}-${GOST_V2}.gz"
        info "دانلود Gost v${GOST_V2} (${g})..."
        curl -fL --retry 3 --retry-delay 2 -o "$tmp/gost.gz" "$url" || die "دانلود نسخه ۲ شکست خورد."
        [ -s "$tmp/gost.gz" ] || die "فایل دانلود خالی است."
        gunzip -c "$tmp/gost.gz" > "$tmp/gost" || die "استخراج نسخه ۲ شکست خورد."
    else
        url="https://github.com/go-gost/gost/releases/download/v${GOST_V3}/gost_${GOST_V3}_linux_${arch}.tar.gz"
        info "دانلود Gost v${GOST_V3} (${arch})..."
        curl -fL --retry 3 --retry-delay 2 -o "$tmp/gost.tgz" "$url" || die "دانلود نسخه ۳ شکست خورد: $url"
        [ -s "$tmp/gost.tgz" ] || die "فایل دانلود خالی است."
        if [ "$arch" = amd64 ]; then
            echo "${GOST_V3_AMD64_SHA256}  $tmp/gost.tgz" | sha256sum -c - || die "چک‌سام نسخه ۳ با فایل منتشرشده یکی نیست."
        fi
        tar -xzf "$tmp/gost.tgz" -C "$tmp" || die "استخراج نسخه ۳ شکست خورد."
        bin=$(find "$tmp" -type f -name gost | head -n 1)
        [ -n "$bin" ] || die "باینری gost داخل آرشیو نبود."
        cp "$bin" "$tmp/gost.bin"
        mv "$tmp/gost.bin" "$tmp/gost"
    fi
    chmod 755 "$tmp/gost"
    mv "$tmp/gost" "$BIN"
    rm -rf "$tmp"
    ok "نصب شد: $("$BIN" -V 2>&1 | head -n 1)"
}

gost_major(){
    local v
    [ -x "$BIN" ] || { echo 0; return 0; }
    v=$("$BIN" -V 2>&1 || true)
    if grep -q '3\.' <<<"$v"; then echo 3
    elif grep -q '2\.' <<<"$v"; then echo 2
    else echo 0
    fi
}

choose_and_install(){
    local cur choice
    cur=$(gost_major)
    if [ "$cur" != 0 ]; then
        info "نسخه فعلی: $("$BIN" -V 2>&1 | head -n 1)"
        read -r -p "همین بماند؟ [Y/n] " choice
        [ "${choice:-Y}" = "Y" ] || [ "${choice:-Y}" = "y" ] && return 0
    fi
    echo "نسخه Gost:"
    echo "  1) ${GOST_V3} پایدار، پیشنهادی"
    echo "  2) ${GOST_V2} قدیمی"
    read -r -p "انتخاب [1]: " choice
    case "${choice:-1}" in
        1) install_gost 3 ;;
        2) install_gost 2 ;;
        *) die "انتخاب نامعتبر." ;;
    esac
}

remove_legacy_units(){
    local u
    shopt -s nullglob
    for u in /etc/systemd/system/gost_*.service /usr/lib/systemd/system/gost_*.service \
             /etc/systemd/system/multi-user.target.wants/gost_*.service; do
        systemctl disable --now "$(basename "$u")" >/dev/null 2>&1 || true
        rm -f "$u"
    done
    shopt -u nullglob
    if [ -f /etc/systemd/system/sysctl-custom.service ]; then
        systemctl disable --now sysctl-custom >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/sysctl-custom.service
        rm -f /etc/systemd/system/multi-user.target.wants/sysctl-custom.service
    fi
    sed -i '/alias gost=/d' /root/.bashrc 2>/dev/null || true
    for u in ${UNIT_DIR}/gost-fwd-*.service; do
        [ -f "$u" ] || continue
        systemctl disable --now "$(basename "$u")" >/dev/null 2>&1 || true
        rm -f "$u"
    done
    rm -f "$CONF_DIR"/fwd-*.yaml "$CONF_DIR"/fwd-*.json "$CONF_DIR"/fwd-*.meta
    rm -f "$CONF_DIR/ports.used"
}

stop_our_units(){
    local u
    for u in ${UNIT_DIR}/gost-fwd-*.service; do
        [ -f "$u" ] || continue
        systemctl disable --now "$(basename "$u")" >/dev/null 2>&1 || true
        rm -f "$u"
    done
    rm -f "$CONF_DIR"/fwd-*.yaml "$CONF_DIR"/fwd-*.json "$CONF_DIR"/fwd-*.meta
    : > "$CONF_DIR/ports.used"
}

next_index(){
    local n=0 base
    for base in ${UNIT_DIR}/gost-fwd-*.service; do
        [ -f "$base" ] || continue
        n=$(( n + 1 ))
    done
    echo "$n"
}

write_forward(){
    local dest=$1 proto=$2 replace=$3
    local host major idx file n_in_file total port i s e
    host=$(dest_host "$dest") || die "آی‌پی مقصد نامعتبر است."
    major=$(gost_major)
    [ "$major" = 0 ] && die "اول Gost را نصب کن."
    mkdir -p "$CONF_DIR"
    if [ "$replace" = 1 ]; then
        stop_our_units
        remove_legacy_units
        mkdir -p "$CONF_DIR"
    else
        for i in "${!STARTS[@]}"; do
            overlaps_used "${STARTS[$i]}" "${ENDS[$i]}" && die "پورت تکراری را برندار، یا از نو نصب کن."
        done
    fi
    idx=$(next_index)
    total=0
    n_in_file=0
    file=""
    open_chunk(){
        file="$CONF_DIR/fwd-${idx}"
        if [ "$major" = 3 ]; then
            cat > "${file}.yaml" <<'EOF'
log:
  level: error
services:
EOF
        else
            printf '%s\n' '{' '"Debug": false,' '"Retries": 1,' '"ServeNodes": [' > "${file}.json"
        fi
        n_in_file=0
    }
    close_chunk(){
        [ -n "$file" ] || return 0
        [ "$n_in_file" -gt 0 ] || return 0
        if [ "$major" = 3 ]; then
            :
        else
            # drop trailing comma
            sed -i '$ s/,$//' "${file}.json"
            printf '%s\n' ']' '}' >> "${file}.json"
        fi
        cat > "${file}.meta" <<EOF
proto=${proto}
dest=${dest}
count=${n_in_file}
EOF
        cat > "${UNIT_DIR}/gost-fwd-${idx}.service" <<EOF
[Unit]
Description=Gost forward ${idx} (${proto} -> ${dest})
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=0

[Service]
Type=simple
WorkingDirectory=${CONF_DIR}
ExecStart=${BIN} -C ${file}.$([ "$major" = 3 ] && echo yaml || echo json)
Restart=always
RestartSec=3
LimitNOFILE=${NOFILE}
LimitNPROC=65535
TasksMax=infinity

[Install]
WantedBy=multi-user.target
EOF
        idx=$(( idx + 1 ))
        file=""
        n_in_file=0
    }
    append_port(){
        local p=$1 htype ltype
        htype=$proto
        ltype=$proto
        if [ "$proto" = grpc ]; then
            htype=tcp
            ltype=grpc
        fi
        if [ "$n_in_file" -eq 0 ]; then open_chunk; fi
        if [ "$major" = 3 ]; then
            {
                echo "- name: p${p}"
                echo "  addr: \":${p}\""
                echo "  handler:"
                echo "    type: ${htype}"
                echo "  listener:"
                echo "    type: ${ltype}"
                if [ "$proto" = udp ]; then
                    echo "    metadata:"
                    echo "      keepAlive: true"
                    echo "      ttl: 60s"
                    echo "      readBufferSize: 8192"
                fi
                echo "  forwarder:"
                echo "    nodes:"
                echo "    - name: t${p}"
                echo "      addr: \"${host}:${p}\""
            } >> "${file}.yaml"
        else
            printf '        "%s://:%s/%s:%s",\n' "$proto" "$p" "$host" "$p" >> "${file}.json"
        fi
        n_in_file=$(( n_in_file + 1 ))
        total=$(( total + 1 ))
        if [ "$n_in_file" -ge "$CHUNK" ]; then close_chunk; fi
    }
    local first_idx=$idx
    for i in "${!STARTS[@]}"; do
        s=${STARTS[$i]}
        e=${ENDS[$i]}
        echo "x ${s} ${e}" >> "$CONF_DIR/ports.pending"
        for ((port=s; port<=e; port++)); do
            append_port "$port"
        done
    done
    close_chunk
    if [ -f "$CONF_DIR/ports.pending" ]; then
        while read -r _ s e; do
            echo "fwd ${s} ${e}" >> "$CONF_DIR/ports.used"
        done < "$CONF_DIR/ports.pending"
        rm -f "$CONF_DIR/ports.pending"
    fi
    sync_reserved_ports
    systemctl daemon-reload
    local u num
    for u in ${UNIT_DIR}/gost-fwd-*.service; do
        [ -f "$u" ] || continue
        num=${u##*-}
        num=${num%.service}
        [ "$num" -ge "$first_idx" ] 2>/dev/null || continue
        systemctl enable "$(basename "$u")" >/dev/null 2>&1 || true
        systemctl restart "$(basename "$u")" || warn "سرویس $(basename "$u") بالا نیامد. journalctl -u $(basename "$u") -n 30"
    done
    ok "فوروارد ${proto} به ${dest} برای ${total} پورت ساخته شد."
}

sync_reserved_ports(){
    local line="" s e
    [ -f "$CONF_DIR/ports.used" ] || return 0
    while read -r _ s e; do
        [ -n "${s:-}" ] || continue
        if [ "$s" = "$e" ]; then line+="${line:+,}${s}"
        else line+="${line:+,}${s}-${e}"
        fi
    done < "$CONF_DIR/ports.used"
    [ -n "$line" ] || return 0
    cat > "$SYSCTL_PORTS" <<EOF
# Ports Gost is listening on. The kernel will not pick them as ephemeral ports.
net.ipv4.ip_local_reserved_ports = ${line}
EOF
    sysctl -e -p "$SYSCTL_PORTS" >/dev/null 2>&1 || warn "اعمال ip_local_reserved_ports ناموفق بود."
}

mem_mb(){ awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo; }

optimize_server(){
    need_root
    local mem cpus rmem ct somax backlog minfree
    mem=$(mem_mb)
    cpus=$(nproc 2>/dev/null || echo 1)
    if   [ "$mem" -ge 8192 ]; then rmem=16777216; ct=524288; somax=16384
    elif [ "$mem" -ge 4096 ]; then rmem=16777216; ct=262144; somax=8192
    elif [ "$mem" -ge 2048 ]; then rmem=8388608;  ct=131072; somax=8192
    else                           rmem=4194304;  ct=65536;  somax=4096
    fi
    if [ "$cpus" -le 1 ]; then backlog=16384; else backlog=32768; fi
    minfree=$(( mem * 16 ))
    [ "$minfree" -lt 16384 ] && minfree=16384
    [ "$minfree" -gt 262144 ] && minfree=262144
    modprobe tcp_bbr 2>/dev/null || true
    modprobe sch_fq 2>/dev/null || true
    modprobe nf_conntrack 2>/dev/null || true
    local cc=cubic qdisc=fq_codel avail
    avail=$(cat /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null || true)
    if grep -qw bbr <<<"$avail"; then cc=bbr; qdisc=fq; fi
    info "بهینه‌سازی تانل: ${cc} + ${qdisc} | ${cpus} هسته | ${mem}MB"
    cat > "$SYSCTL_MAIN" <<EOF
# Tunnel optimizer, applied by gost-tunnel.sh
net.ipv4.ip_forward = 1
net.ipv4.conf.all.src_valid_mark = 1
net.ipv4.conf.default.src_valid_mark = 1
net.ipv4.conf.all.rp_filter = 2
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.core.default_qdisc = ${qdisc}
net.ipv4.tcp_congestion_control = ${cc}
net.core.rmem_max = ${rmem}
net.core.wmem_max = ${rmem}
net.ipv4.tcp_rmem = 4096 131072 ${rmem}
net.ipv4.tcp_wmem = 4096 131072 ${rmem}
net.ipv4.udp_rmem_min = 16384
net.ipv4.udp_wmem_min = 16384
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_fastopen = 3
net.core.netdev_max_backlog = ${backlog}
net.core.somaxconn = ${somax}
net.ipv4.tcp_max_syn_backlog = ${somax}
net.ipv4.ip_local_port_range = 10240 65535
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
fs.file-max = 2097152
fs.nr_open = 2097152
vm.swappiness = 10
vm.min_free_kbytes = ${minfree}
vm.overcommit_memory = 1
net.netfilter.nf_conntrack_max = ${ct}
EOF
    sysctl -e -p "$SYSCTL_MAIN" >/dev/null 2>&1 || warn "بعضی کلیدهای sysctl روی این کرنل نیستند."
    for rp in /proc/sys/net/ipv4/conf/*/rp_filter; do
        [ -w "$rp" ] && echo 2 > "$rp" 2>/dev/null || true
    done
    if [ -w /sys/module/nf_conntrack/parameters/hashsize ]; then
        echo $(( ct / 4 )) > /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null || true
    fi
    sysctl -e -qw \
        net.netfilter.nf_conntrack_tcp_be_liberal=1 \
        net.netfilter.nf_conntrack_udp_timeout=60 \
        net.netfilter.nf_conntrack_udp_timeout_stream=300 \
        2>/dev/null || true
    sync_reserved_ports
    mkdir -p /etc/security/limits.d /etc/systemd/system.conf.d
    cat > /etc/security/limits.d/99-tunnel.conf <<EOF
* soft nofile ${NOFILE}
* hard nofile ${NOFILE}
root soft nofile ${NOFILE}
root hard nofile ${NOFILE}
EOF
    cat > /etc/systemd/system.conf.d/99-tunnel-limits.conf <<EOF
[Manager]
DefaultLimitNOFILE=${NOFILE}
EOF
    local u dir
    for u in ${UNIT_DIR}/gost-fwd-*.service /etc/systemd/system/gost_*.service; do
        [ -f "$u" ] || continue
        dir="${UNIT_DIR}/$(basename "$u").d"
        mkdir -p "$dir"
        cat > "$dir/99-tunnel-limits.conf" <<EOF
[Service]
LimitNOFILE=${NOFILE}
LimitNPROC=65535
TasksMax=infinity
EOF
    done
    cat > "$NET_SCRIPT" <<'EOF'
#!/usr/bin/env bash
set -u
SYSCTL=/etc/sysctl.d/99-tunnel-optimize.conf
PORTS=/etc/sysctl.d/98-gost-ports.conf
CHAIN=TUNNEL_OPT
[ -f "$SYSCTL" ] && sysctl -e -p "$SYSCTL" >/dev/null 2>&1 || true
[ -f "$PORTS" ] && sysctl -e -p "$PORTS" >/dev/null 2>&1 || true
modprobe tcp_bbr 2>/dev/null || true
modprobe sch_fq 2>/dev/null || true
modprobe nf_conntrack 2>/dev/null || true
for rp in /proc/sys/net/ipv4/conf/*/rp_filter; do
    [ -w "$rp" ] && echo 2 > "$rp" 2>/dev/null || true
done
if command -v iptables >/dev/null 2>&1; then
    while iptables -t mangle -D POSTROUTING -j "$CHAIN" 2>/dev/null; do :; done
    iptables -t mangle -F "$CHAIN" 2>/dev/null || true
    iptables -t mangle -X "$CHAIN" 2>/dev/null || true
    iptables -t mangle -N "$CHAIN" 2>/dev/null || true
    iptables -t mangle -A POSTROUTING -j "$CHAIN" 2>/dev/null || true
    iptables -t mangle -A "$CHAIN" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
fi
if command -v tc >/dev/null 2>&1; then
    for path in /sys/class/net/*; do
        iface=$(basename "$path")
        case "$iface" in
            lo|docker*|veth*|br-*|virbr*|wg*|tun*|sit*|gre*|dummy*) continue ;;
        esac
        state=$(cat "$path/operstate" 2>/dev/null || echo down)
        [ "$state" = up ] || [ "$state" = unknown ] || continue
        ip link set dev "$iface" txqueuelen 10000 2>/dev/null || true
        root=$(tc qdisc show dev "$iface" 2>/dev/null | awk 'NR==1{print $2}')
        case "$root" in
            mq|mqprio|fq|fq_pie) ;;
            *) tc qdisc replace dev "$iface" root fq 2>/dev/null || true ;;
        esac
    done
fi
exit 0
EOF
    chmod 755 "$NET_SCRIPT"
    cat > "$NET_UNIT" <<'EOF'
[Unit]
Description=Tunnel network tweaks for Gost
After=network-online.target
Before=gost-fwd-0.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/tunnel-net-tweaks.sh

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now tunnel-net-tweaks.service >/dev/null 2>&1 || true
    systemctl restart tunnel-net-tweaks.service >/dev/null 2>&1 || warn "سرویس tweaks هشدار داد."
    local unit
    for unit in ${UNIT_DIR}/gost-fwd-*.service; do
        [ -f "$unit" ] || continue
        systemctl try-restart "$(basename "$unit")" >/dev/null 2>&1 || true
    done
    ok "بهینه شد. BBR=${cc}  forward=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo ?)  rp_filter=$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null || echo ?)"
    ok "کش پاک نمی‌شود. drop_caches روی تانل زنده فقط کندش می‌کند."
}

show_status(){
    echo
    if [ -x "$BIN" ]; then ok "Gost: $("$BIN" -V 2>&1 | head -n 1)"
    else warn "Gost نصب نیست."; fi
    echo "  congestion: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')"
    echo "  ip_forward: $(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo '?')"
    echo "  rp_filter:  $(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null || echo '?')"
    local meta dest proto count unit
    shopt -s nullglob
    for meta in "$CONF_DIR"/fwd-*.meta; do
        proto=$(sed -n 's/^proto=//p' "$meta")
        dest=$(sed -n 's/^dest=//p' "$meta")
        count=$(sed -n 's/^count=//p' "$meta")
        unit="gost-fwd-$(basename "$meta" .meta | sed 's/fwd-//').service"
        # basename fwd-3.meta -> unit gost-fwd-3
        unit="gost-fwd-${meta##*/fwd-}"
        unit="${unit%.meta}.service"
        printf '  %-22s %-8s -> %-40s %s پورت  [%s]\n' \
            "$unit" "$proto" "$dest" "$count" "$(systemctl is-active "$unit" 2>/dev/null || echo unknown)"
    done
    shopt -u nullglob
    if ls /usr/lib/systemd/system/gost_*.service >/dev/null 2>&1 || ls /etc/systemd/system/gost_*.service >/dev/null 2>&1; then
        warn "یونیت قدیمی gost_*.service هنوز هست. یک بار نصب را با جایگزینی انجام بده."
    fi
    echo
}

schedule_restart(){
    local h action
    echo "  1) روشن"
    echo "  2) خاموش"
    read -r -p "انتخاب: " action
    case "$action" in
        2)
            crontab -l 2>/dev/null | grep -v '/usr/local/sbin/gost-auto-restart.sh' | crontab - || true
            rm -f /usr/local/sbin/gost-auto-restart.sh
            ok "ری‌استارت زمان‌بندی‌شده حذف شد."
            return 0
            ;;
        1) ;;
        *) warn "لغو."; return 0 ;;
    esac
    read -r -p "هر چند ساعت یک بار؟ (۱ تا ۲۳): " h
    [[ "$h" =~ ^[0-9]+$ ]] && [ "$h" -ge 1 ] && [ "$h" -le 23 ] || die "ساعت نامعتبر است."
    cat > /usr/local/sbin/gost-auto-restart.sh <<'EOF'
#!/usr/bin/env bash
shopt -s nullglob
units=(${UNIT_DIR}/gost-fwd-*.service)
[ "${#units[@]}" -gt 0 ] || exit 0
systemctl restart "${units[@]##*/}"
EOF
    chmod 755 /usr/local/sbin/gost-auto-restart.sh
    (crontab -l 2>/dev/null | grep -v '/usr/local/sbin/gost-auto-restart.sh' || true
     echo "0 */${h} * * * /usr/local/sbin/gost-auto-restart.sh") | crontab -
    ok "هر ${h} ساعت Gost ری‌استارت می‌شود."
}

uninstall_all(){
    local yn
    read -r -p "Gost و فورواردها پاک شوند؟ [y/N] " yn
    [ "$yn" = "y" ] || [ "$yn" = "Y" ] || { ok "لغو شد."; return 0; }
    stop_our_units
    remove_legacy_units
    crontab -l 2>/dev/null | grep -v '/usr/local/sbin/gost-auto-restart.sh' | crontab - || true
    rm -f /usr/local/sbin/gost-auto-restart.sh "$BIN"
    rm -f "$SYSCTL_PORTS"
    systemctl daemon-reload || true
    read -r -p "تنظیمات بهینه‌ساز کرنل هم پاک شود؟ [y/N] " yn
    if [ "$yn" = "y" ] || [ "$yn" = "Y" ]; then
        systemctl disable --now tunnel-net-tweaks.service >/dev/null 2>&1 || true
        rm -f "$NET_UNIT" "$NET_SCRIPT" "$SYSCTL_MAIN"
        while iptables -t mangle -D POSTROUTING -j "$CHAIN" 2>/dev/null; do :; done
        iptables -t mangle -F "$CHAIN" 2>/dev/null || true
        iptables -t mangle -X "$CHAIN" 2>/dev/null || true
        sysctl --system >/dev/null 2>&1 || true
    fi
    ok "حذف شد."
}

install_menu_cmd(){
    local src
    src=$(readlink -f "$0" 2>/dev/null || echo "$0")
    [ -f "$src" ] || return 0
    if [ "$src" != "$(readlink -f "$MENU_BIN" 2>/dev/null || echo "")" ]; then
        cp "$src" "$MENU_BIN"
        chmod 755 "$MENU_BIN"
    fi
}

create_tunnel(){
    local kind=$1 dest proto yn n
    choose_and_install
    dest=$(ask_ip "$kind")
    ask_ports
    proto=$(ask_proto)
    n=$(port_count)
    echo
    info "مقصد: ${dest}   پروتکل: ${proto}   تعداد: ${n}"
    if ls ${UNIT_DIR}/gost-fwd-*.service >/dev/null 2>&1; then
        echo "  1) جایگزین همه فورواردهای قبلی"
        echo "  2) اضافه به فورواردهای فعلی"
        read -r -p "انتخاب [2]: " yn
        if [ "${yn:-2}" = 1 ]; then write_forward "$dest" "$proto" 1
        else write_forward "$dest" "$proto" 0
        fi
    else
        write_forward "$dest" "$proto" 1
    fi
    read -r -p "بهینه‌ساز تانل هم اعمال شود؟ [Y/n] " yn
    if [ "${yn:-Y}" = "Y" ] || [ "${yn:-Y}" = "y" ]; then
        optimize_server
    fi
    show_status
}

add_forward(){
    local dest proto ipkind
    [ -x "$BIN" ] || die "اول از منوی ۱ یا ۲ تانل را بساز."
    echo "  1) IPv4    2) IPv6"
    read -r -p "نوع آی‌پی مقصد [1]: " ipkind
    case "${ipkind:-1}" in
        1) dest=$(ask_ip 4) ;;
        2) dest=$(ask_ip 6) ;;
        *) die "انتخاب نامعتبر." ;;
    esac
    ask_ports
    proto=$(ask_proto)
    write_forward "$dest" "$proto" 0
    show_status
}

menu(){
    local choice
    while true; do
        echo
        printf '%sGost Tunnel + Optimizer%s\n' "$B" "$N"
        echo "  1) تانل با آی‌پی ۴ خارج"
        echo "  2) تانل با آی‌پی ۶ خارج"
        echo "  3) وضعیت"
        echo "  4) اضافه کردن پورت یا آی‌پی"
        echo "  5) نصب یا عوض کردن نسخه Gost"
        echo "  6) ری‌استارت زمان‌بندی‌شده"
        echo "  7) بهینه‌سازی سرور تانل"
        echo "  8) حذف"
        echo "  0) خروج"
        read -r -p "انتخاب: " choice
        case "$choice" in
            1) create_tunnel 4 ;;
            2) create_tunnel 6 ;;
            3) show_status ;;
            4) add_forward ;;
            5) choose_and_install ;;
            6) schedule_restart ;;
            7) optimize_server; show_status ;;
            8) uninstall_all ;;
            0) exit 0 ;;
            *) warn "عدد منو را بزن." ;;
        esac
    done
}

self_test(){
    local tmp=$1
    CONF_DIR=$tmp/conf
    UNIT_DIR=$tmp/units
    SYSCTL_PORTS=$tmp/ports.conf
    BIN=/bin/true
    mkdir -p "$CONF_DIR" "$UNIT_DIR"
    systemctl(){ return 0; }
    gost_major(){ echo 3; }
    parse_port_spec "443,2053,1000-1002" 0 || die "parse list failed"
    [ "$(port_count)" -eq 5 ] || die "count want 5 got $(port_count)"
    parse_port_spec "54,80" 1 || die "parse old range failed"
    [ "${STARTS[0]}" = 54 ] && [ "${ENDS[0]}" = 80 ] || die "old range not expanded"
    parse_port_spec "70000-70001" 0 && die "high port should fail"
    parse_port_spec "10-5" 0 && die "reverse range should fail"
    is_ipv4 1.2.3.4 || die "ipv4"
    is_ipv4 1.2.3.256 && die "ipv4 octet"
    is_ipv6 2001:db8::1 || die "ipv6"
    is_ipv6 1.2.3.4 && die "ipv4 detected as ipv6"
    [ "$(dest_host 2001:db8::1)" = "[2001:db8::1]" ] || die "bracket"
    [ "$(dest_host 1.2.3.4)" = "1.2.3.4" ] || die "v4 host"

    CHUNK=2
    STARTS=(443 1000)
    ENDS=(444 1001)
    write_forward 2001:db8::1 udp 0
    grep -q '\[2001:db8::1\]:443' "$CONF_DIR/fwd-0.yaml" || die "yaml missing ipv6 brackets"
    grep -q '^    metadata:' "$CONF_DIR/fwd-0.yaml" || die "udp metadata not under listener"
    grep -q 'LimitNOFILE=1048576' "$UNIT_DIR/gost-fwd-0.service" || die "nofile"
    grep -q 'fwd-0.yaml' "$UNIT_DIR/gost-fwd-0.service" || die "unit config path"
    [ -f "$UNIT_DIR/gost-fwd-1.service" ] || die "chunk was not split"
    grep -q '443-444,1000-1001' "$SYSCTL_PORTS" || die "reserved ports: $(cat "$SYSCTL_PORTS")"
    overlaps_used 444 444 || die "overlap was not recorded"
    overlaps_used 2000 2001 && die "false overlap"

    rm -rf "$CONF_DIR" "$UNIT_DIR" "$SYSCTL_PORTS"
    mkdir -p "$CONF_DIR" "$UNIT_DIR"
    gost_major(){ echo 2; }
    STARTS=(80)
    ENDS=(80)
    write_forward 1.2.3.4 tcp 0
    grep -q 'tcp://:80/1.2.3.4:80' "$CONF_DIR/fwd-0.json" || die "v2 node"
    python3 -m json.tool "$CONF_DIR/fwd-0.json" >/dev/null || die "v2 json invalid"

    rm -rf "$CONF_DIR" "$UNIT_DIR" "$SYSCTL_PORTS"
    mkdir -p "$CONF_DIR" "$UNIT_DIR"
    gost_major(){ echo 3; }
    STARTS=(90)
    ENDS=(90)
    write_forward 8.8.8.8 grpc 0
    grep -q 'type: grpc' "$CONF_DIR/fwd-0.yaml" || die "grpc listener"
    grep -q 'type: tcp' "$CONF_DIR/fwd-0.yaml" || die "grpc handler"
    ok "self-test passed"
}

case "${1:-}" in
    --self-test) self_test "${2:-/tmp/gost-selftest}"; exit 0 ;;
    --optimize) need_root; optimize_server; exit 0 ;;
    --status) show_status; exit 0 ;;
    "") ;;
    *) die "آرگومان ناشناخته: $1" ;;
esac

need_root
install_menu_cmd
menu
