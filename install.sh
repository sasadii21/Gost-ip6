#!/usr/bin/env bash
# Gost tunnel installer, bugfixed, with the tunnel optimizer built in.
# Listen on this server and forward each port to the same port on the foreign (Kharej) server.
# Does not use one giant ExecStart, does not write rc.local, does not alias over gost.
#
#   sudo bash gost-tunnel.sh
#   sudo bash gost-tunnel.sh --optimize
#   sudo bash gost-tunnel.sh --status
#        bash gost-tunnel.sh --self-test
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
RESTART_SCRIPT=/usr/local/sbin/gost-auto-restart.sh
LIMITS_CONF=/etc/security/limits.d/99-tunnel.conf
SYSTEMD_LIMITS_CONF=/etc/systemd/system.conf.d/99-tunnel-limits.conf
CHAIN=TUNNEL_OPT
CHUNK=1500
NOFILE=1048576

# Result variables. Interactive helpers set these instead of printing to stdout,
# because anything printed inside $(...) would be captured and never shown.
ARCH=""
DEST_IP=""
PROTO=""
TMP_DIR=""

R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; B=$'\e[1m'; N=$'\e[0m'
info(){ printf '%s➜%s %s\n' "$C" "$N" "$*"; }
ok(){ printf '%s✔%s %s\n' "$G" "$N" "$*"; }
warn(){ printf '%s!%s %s\n' "$Y" "$N" "$*" >&2; }
die(){
    printf '%s✖%s %s\n' "$R" "$N" "$*" >&2
    [ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR"
    exit 1
}

need_root(){ [ "$(id -u)" -eq 0 ] || die "Run as root: sudo bash gost-tunnel.sh"; }

cpu_arch(){
    case "$(uname -m)" in
        x86_64|amd64) ARCH=amd64 ;;
        aarch64|arm64) ARCH=arm64 ;;
        armv7l|armv7) ARCH=armv7 ;;
        i386|i686) ARCH=386 ;;
        *) die "Architecture $(uname -m) is not supported." ;;
    esac
}

is_ipv4(){
    local ip=$1 o o1 o2 o3 o4
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    IFS=. read -r o1 o2 o3 o4 <<<"$ip"
    for o in "$o1" "$o2" "$o3" "$o4"; do
        [[ "$o" =~ ^(0|[1-9][0-9]*)$ ]] || return 1   # no leading zeros
        [ "$o" -le 255 ] || return 1
    done
    return 0
}

is_ipv6(){
    local ip=$1 head tail part g n=0
    local -a groups
    [[ "$ip" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
    [[ "$ip" == *:* ]] || return 1
    [[ "$ip" == *:::* ]] && return 1
    if [[ "$ip" == *::* ]]; then
        head=${ip%%::*}
        tail=${ip#*::}
        [[ "$tail" == *::* ]] && return 1            # only one "::" allowed
        for part in "$head" "$tail"; do
            [ -n "$part" ] || continue
            [[ "$part" == :* || "$part" == *: ]] && return 1
            IFS=: read -ra groups <<<"$part"
            for g in "${groups[@]}"; do
                [[ "$g" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
                n=$(( n + 1 ))
            done
        done
        [ "$n" -le 7 ]
    else
        [[ "$ip" == :* || "$ip" == *: ]] && return 1
        IFS=: read -ra groups <<<"$ip"
        [ "${#groups[@]}" -eq 8 ] || return 1
        for g in "${groups[@]}"; do
            [[ "$g" =~ ^[0-9A-Fa-f]{1,4}$ ]] || return 1
        done
    fi
}

dest_host(){
    # $1 = ip, prints the host part of host:port
    if is_ipv4 "$1"; then printf '%s' "$1"
    elif is_ipv6 "$1"; then printf '[%s]' "$1"
    else return 1
    fi
}

# Sets DEST_IP.
ask_ip(){
    local kind=$1 ip
    while true; do
        if [ "$kind" = 6 ]; then
            read -r -p $'\e[97mForeign server IPv6 address: \e[0m' ip || die "Input closed."
            if is_ipv6 "$ip"; then DEST_IP=$ip; return 0; fi
            warn "Invalid IPv6 address."
        else
            read -r -p $'\e[97mForeign server IPv4 address: \e[0m' ip || die "Input closed."
            if is_ipv4 "$ip"; then DEST_IP=$ip; return 0; fi
            warn "Invalid IPv4 address."
        fi
    done
}

# Sets PROTO.
ask_proto(){
    local p
    echo "Protocol:"
    echo "  1) TCP   for Reality / VLESS / Trojan"
    echo "  2) UDP   for Hysteria / TUIC"
    echo "  3) gRPC  only if the client side is also Gost, not for regular clients (Gost v3 only)"
    read -r -p "Choice [1]: " p || die "Input closed."
    case "${p:-1}" in
        1|tcp|TCP) PROTO=tcp ;;
        2|udp|UDP) PROTO=udp ;;
        3|grpc|GRPC) PROTO=grpc ;;
        *) die "Invalid protocol." ;;
    esac
}

# Fills STARTS ENDS arrays. Accepts 443,2053 and 1000-20000.
# range_mode=1 treats "1000,20000" as a range, like the old script.
parse_port_spec(){
    local spec=$1 range_mode=$2 part a b i j
    local -a parts
    STARTS=()
    ENDS=()
    spec=${spec// /}
    [ -n "$spec" ] || return 1
    [[ "$spec" == *, ]] && return 1                  # read -a silently drops a trailing empty field
    if [ "$range_mode" = 1 ] && [[ "$spec" =~ ^([0-9]+),([0-9]+)$ ]]; then
        spec="${BASH_REMATCH[1]}-${BASH_REMATCH[2]}"
    fi
    IFS=',' read -ra parts <<<"$spec"
    for part in "${parts[@]}"; do
        [ -n "$part" ] || return 1
        # 10# forces base 10: a port like 0443 or 0899 must not be parsed as octal.
        if [[ "$part" =~ ^([0-9]{1,5})-([0-9]{1,5})$ ]]; then
            a=$(( 10#${BASH_REMATCH[1]} ))
            b=$(( 10#${BASH_REMATCH[2]} ))
        elif [[ "$part" =~ ^[0-9]{1,5}$ ]]; then
            a=$(( 10#$part ))
            b=$a
        else
            return 1
        fi
        [ "$a" -ge 1 ] && [ "$b" -le 65535 ] && [ "$a" -le "$b" ] || return 1
        STARTS+=("$a")
        ENDS+=("$b")
    done
    [ "${#STARTS[@]}" -gt 0 ] || return 1
    # Reject overlaps inside the same input (would create two listeners on one port).
    for i in "${!STARTS[@]}"; do
        for (( j = i + 1; j < ${#STARTS[@]}; j++ )); do
            if [ "${STARTS[i]}" -le "${ENDS[j]}" ] && [ "${ENDS[i]}" -ge "${STARTS[j]}" ]; then
                warn "Ports ${STARTS[i]}-${ENDS[i]} and ${STARTS[j]}-${ENDS[j]} overlap."
                return 1
            fi
        done
    done
    return 0
}

port_count(){
    local i n=0
    for i in "${!STARTS[@]}"; do
        n=$(( n + ENDS[i] - STARTS[i] + 1 ))
    done
    echo "$n"
}

ask_ports(){
    local mode spec n yn
    echo "Ports:"
    echo "  1) List, e.g. 443,2053,8443"
    echo "  2) Range, e.g. 10000-40000   (the old form 10000,40000 is accepted too)"
    read -r -p "Choice [1]: " mode || die "Input closed."
    case "${mode:-1}" in
        1) read -r -p "Ports: " spec || die "Input closed."
           parse_port_spec "$spec" 0 || die "Invalid port list." ;;
        2) read -r -p "Range: " spec || die "Input closed."
           parse_port_spec "$spec" 1 || die "Invalid port range. Use 1-65535." ;;
        *) die "Invalid choice." ;;
    esac
    n=$(port_count)
    [ "$n" -gt 0 ] || die "No ports selected."
    if [ "$n" -gt 30000 ]; then
        warn "$n ports is a lot and will use a lot of RAM."
        read -r -p "Continue? [y/N] " yn || die "Input closed."
        [ "$yn" = "y" ] || [ "$yn" = "Y" ] || die "Cancelled."
    fi
    info "$n ports will be registered."
}

overlaps_used(){
    local s=$1 e=$2 a b
    [ -f "$CONF_DIR/ports.used" ] || return 1
    while read -r _ a b; do
        [ -n "${a:-}" ] || continue
        if [ "$s" -le "$b" ] && [ "$e" -ge "$a" ]; then
            warn "Ports ${s}-${e} overlap with existing forward ${a}-${b}."
            return 0
        fi
    done < "$CONF_DIR/ports.used"
    return 1
}

ensure_pkgs(){
    command -v curl >/dev/null 2>&1 && return 0
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update -qq || true
        apt-get install -y -qq curl ca-certificates || die "Could not install curl."
    else
        die "curl is missing and apt was not found."
    fi
}

install_gost(){
    local major=$1 url src g
    ensure_pkgs
    cpu_arch
    TMP_DIR=$(mktemp -d) || die "Could not create a temporary directory."
    if [ "$major" = 2 ]; then
        case "$ARCH" in
            amd64) g=amd64 ;;
            arm64) g=armv8 ;;
            armv7) g=armv7 ;;
            386) g=386 ;;
        esac
        url="https://github.com/ginuerzh/gost/releases/download/v${GOST_V2}/gost-linux-${g}-${GOST_V2}.gz"
        info "Downloading Gost v${GOST_V2} (${g})..."
        curl -fL --retry 3 --retry-delay 2 -o "$TMP_DIR/gost.gz" "$url" || die "Downloading v2 failed."
        [ -s "$TMP_DIR/gost.gz" ] || die "The downloaded file is empty."
        gunzip -c "$TMP_DIR/gost.gz" > "$TMP_DIR/gost" || die "Extracting v2 failed."
        src="$TMP_DIR/gost"
    else
        url="https://github.com/go-gost/gost/releases/download/v${GOST_V3}/gost_${GOST_V3}_linux_${ARCH}.tar.gz"
        info "Downloading Gost v${GOST_V3} (${ARCH})..."
        curl -fL --retry 3 --retry-delay 2 -o "$TMP_DIR/gost.tgz" "$url" || die "Downloading v3 failed: $url"
        [ -s "$TMP_DIR/gost.tgz" ] || die "The downloaded file is empty."
        if [ "$ARCH" = amd64 ]; then
            echo "${GOST_V3_AMD64_SHA256}  $TMP_DIR/gost.tgz" | sha256sum -c - || die "The v3 checksum does not match the published file."
        else
            warn "No pinned checksum for ${ARCH}; skipping verification."
        fi
        tar -xzf "$TMP_DIR/gost.tgz" -C "$TMP_DIR" || die "Extracting v3 failed."
        src=$(find "$TMP_DIR" -type f -name gost | head -n 1)
        [ -n "$src" ] || die "The gost binary was not found inside the archive."
    fi
    chmod 755 "$src"
    "$src" -V >/dev/null 2>&1 || die "The downloaded binary does not run on this machine."
    # Copy next to the target, then rename over it. Renaming works even while the old
    # binary is running; writing straight into a running binary fails with "Text file busy".
    install -m 755 "$src" "${BIN}.new" || die "Could not write ${BIN}.new"
    mv -f "${BIN}.new" "$BIN" || die "Could not replace $BIN"
    rm -rf "$TMP_DIR"
    TMP_DIR=""
    ok "Installed: $("$BIN" -V 2>&1 | head -n 1)"
}

# Reads the major version from the first number after "gost ".
# Do not grep for "3." anywhere: it also matches things like "go1.13.3".
major_from_version_line(){
    local n
    n=$(sed -n 's/^gost \([0-9][0-9]*\)\..*/\1/p' <<<"$1" | head -n 1)
    case "$n" in
        2|3) echo "$n" ;;
        *) echo 0 ;;
    esac
}

gost_major(){
    local v
    [ -x "$BIN" ] || { echo 0; return 0; }
    v=$("$BIN" -V 2>&1 | head -n 1 || true)
    major_from_version_line "$v"
}

has_forwards(){ compgen -G "${UNIT_DIR}/gost-fwd-*.service" >/dev/null; }

restart_our_units(){
    local u
    for u in ${UNIT_DIR}/gost-fwd-*.service; do
        [ -f "$u" ] || continue
        systemctl try-restart "$(basename "$u")" >/dev/null 2>&1 || true
    done
}

choose_and_install(){
    local cur choice want
    cur=$(gost_major)
    if [ "$cur" != 0 ]; then
        info "Current version: $("$BIN" -V 2>&1 | head -n 1)"
        read -r -p "Keep it? [Y/n] " choice || die "Input closed."
        [ "${choice:-Y}" = "Y" ] || [ "${choice:-Y}" = "y" ] && return 0
    fi
    echo "Gost version:"
    echo "  1) ${GOST_V3} stable, recommended"
    echo "  2) ${GOST_V2} legacy"
    read -r -p "Choice [1]: " choice || die "Input closed."
    case "${choice:-1}" in
        1) want=3 ;;
        2) want=2 ;;
        *) die "Invalid choice." ;;
    esac
    if [ "$cur" != 0 ] && [ "$cur" != "$want" ] && has_forwards; then
        warn "Switching between Gost v2 and v3 breaks existing forwards (v2 uses JSON configs, v3 uses YAML)."
        read -r -p "Remove all existing forwards and continue? [y/N] " choice || die "Input closed."
        if [ "$choice" = "y" ] || [ "$choice" = "Y" ]; then
            stop_our_units
            systemctl daemon-reload || true
        else
            die "Cancelled."
        fi
    fi
    install_gost "$want"
    restart_our_units
}

remove_legacy_units(){
    local u
    shopt -s nullglob
    for u in /etc/systemd/system/gost_*.service /usr/lib/systemd/system/gost_*.service \
             /etc/systemd/system/multi-user.target.wants/gost_*.service; do
        systemctl disable --now "$(basename "$u")" >/dev/null 2>&1 || true
        rm -f "$u"
        rm -rf "${u}.d"
    done
    shopt -u nullglob
    if [ -f /etc/systemd/system/sysctl-custom.service ]; then
        systemctl disable --now sysctl-custom >/dev/null 2>&1 || true
        rm -f /etc/systemd/system/sysctl-custom.service
        rm -f /etc/systemd/system/multi-user.target.wants/sysctl-custom.service
    fi
    sed -i '/alias gost=/d' /root/.bashrc 2>/dev/null || true
    stop_our_units
}

stop_our_units(){
    local u
    for u in ${UNIT_DIR}/gost-fwd-*.service; do
        [ -f "$u" ] || continue
        systemctl disable --now "$(basename "$u")" >/dev/null 2>&1 || true
        rm -f "$u"
        rm -rf "${u}.d"
    done
    rm -f "$CONF_DIR"/fwd-*.yaml "$CONF_DIR"/fwd-*.json "$CONF_DIR"/fwd-*.meta
    rm -f "$CONF_DIR/ports.used"
}

# Highest existing unit index + 1, so a gap in the numbering can never overwrite a unit.
next_index(){
    local n=-1 u b
    for u in ${UNIT_DIR}/gost-fwd-*.service; do
        [ -f "$u" ] || continue
        b=${u##*-}
        b=${b%.service}
        [[ "$b" =~ ^[0-9]+$ ]] || continue
        b=$(( 10#$b ))
        [ "$b" -gt "$n" ] && n=$b
    done
    echo $(( n + 1 ))
}

write_forward(){
    local dest=$1 proto=$2 replace=$3
    local host major ext idx first_idx file n_in_file total port i s e u num
    host=$(dest_host "$dest") || die "Invalid destination IP address."
    major=$(gost_major)
    [ "$major" = 0 ] && die "Install Gost first."
    if [ "$major" = 2 ] && [ "$proto" = grpc ]; then
        die "gRPC forwarding needs Gost v3 (v2 has no gRPC forward mode)."
    fi
    ext=yaml
    [ "$major" = 2 ] && ext=json
    mkdir -p "$CONF_DIR"
    if [ "$replace" = 1 ]; then
        remove_legacy_units          # also stops and removes our own units
    else
        for i in "${!STARTS[@]}"; do
            overlaps_used "${STARTS[$i]}" "${ENDS[$i]}" && die "Remove the overlapping ports, or choose \"replace all existing forwards\"."
        done
    fi
    idx=$(next_index)
    first_idx=$idx
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
        if [ "$major" = 2 ]; then
            # drop the trailing comma of the last node, then close the JSON
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
ExecStart=${BIN} -C ${file}.${ext}
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
    for i in "${!STARTS[@]}"; do
        s=${STARTS[$i]}
        e=${ENDS[$i]}
        for (( port = s; port <= e; port++ )); do
            append_port "$port"
        done
    done
    close_chunk
    for i in "${!STARTS[@]}"; do
        echo "fwd ${STARTS[$i]} ${ENDS[$i]}" >> "$CONF_DIR/ports.used"
    done
    sync_reserved_ports
    systemctl daemon-reload
    for u in ${UNIT_DIR}/gost-fwd-*.service; do
        [ -f "$u" ] || continue
        num=${u##*-}
        num=${num%.service}
        [ "$num" -ge "$first_idx" ] 2>/dev/null || continue
        systemctl enable "$(basename "$u")" >/dev/null 2>&1 || true
        systemctl restart "$(basename "$u")" || warn "Service $(basename "$u") did not start. See: journalctl -u $(basename "$u") -n 30"
    done
    ok "Created ${proto} forward to ${dest} for ${total} ports."
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
    # The kernel reads at most one page (4 KiB) per sysctl write; a longer list would be cut mid-number.
    if [ "${#line}" -gt 4000 ]; then
        warn "Port list is too long for ip_local_reserved_ports; skipping it. Use ranges instead of many single ports."
        return 0
    fi
    cat > "$SYSCTL_PORTS" <<EOF
# Ports Gost is listening on. The kernel will not pick them as ephemeral ports.
net.ipv4.ip_local_reserved_ports = ${line}
EOF
    sysctl -e -p "$SYSCTL_PORTS" >/dev/null 2>&1 || warn "Applying ip_local_reserved_ports failed."
}

mem_mb(){ awk '/MemTotal/ {print int($2/1024)}' /proc/meminfo; }

optimize_server(){
    need_root
    local mem cpus rmem ct somax backlog minfree rp u dir
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
    info "Tunnel optimizer: ${cc} + ${qdisc} | ${cpus} cores | ${mem}MB"
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
net.netfilter.nf_conntrack_tcp_be_liberal = 1
net.netfilter.nf_conntrack_udp_timeout = 60
net.netfilter.nf_conntrack_udp_timeout_stream = 300
EOF
    sysctl -e -p "$SYSCTL_MAIN" >/dev/null 2>&1 || warn "Some sysctl keys do not exist on this kernel."
    for rp in /proc/sys/net/ipv4/conf/*/rp_filter; do
        [ -w "$rp" ] && echo 2 > "$rp" 2>/dev/null || true
    done
    if [ -w /sys/module/nf_conntrack/parameters/hashsize ]; then
        echo $(( ct / 4 )) > /sys/module/nf_conntrack/parameters/hashsize 2>/dev/null || true
    fi
    sync_reserved_ports
    mkdir -p /etc/security/limits.d /etc/systemd/system.conf.d
    cat > "$LIMITS_CONF" <<EOF
* soft nofile ${NOFILE}
* hard nofile ${NOFILE}
root soft nofile ${NOFILE}
root hard nofile ${NOFILE}
EOF
    cat > "$SYSTEMD_LIMITS_CONF" <<EOF
[Manager]
DefaultLimitNOFILE=${NOFILE}
EOF
    for u in ${UNIT_DIR}/gost-fwd-*.service ${UNIT_DIR}/gost_*.service; do
        [ -f "$u" ] || continue
        dir="${u}.d"
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
for ipt in iptables ip6tables; do
    command -v "$ipt" >/dev/null 2>&1 || continue
    while "$ipt" -t mangle -D POSTROUTING -j "$CHAIN" 2>/dev/null; do :; done
    "$ipt" -t mangle -F "$CHAIN" 2>/dev/null || true
    "$ipt" -t mangle -X "$CHAIN" 2>/dev/null || true
    "$ipt" -t mangle -N "$CHAIN" 2>/dev/null || true
    "$ipt" -t mangle -A POSTROUTING -j "$CHAIN" 2>/dev/null || true
    "$ipt" -t mangle -A "$CHAIN" -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null || true
done
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
    systemctl enable tunnel-net-tweaks.service >/dev/null 2>&1 || true
    systemctl restart tunnel-net-tweaks.service >/dev/null 2>&1 || warn "The tweaks service reported a problem."
    restart_our_units
    ok "Optimized. BBR=${cc}  forward=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo ?)  rp_filter=$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null || echo ?)"
    ok "Caches are not dropped. drop_caches on a live tunnel only slows it down."
}

show_status(){
    local meta proto dest count unit state
    echo
    if [ -x "$BIN" ]; then ok "Gost: $("$BIN" -V 2>&1 | head -n 1)"
    else warn "Gost is not installed."; fi
    echo "  congestion: $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo '?')"
    echo "  ip_forward: $(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo '?')"
    echo "  rp_filter:  $(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null || echo '?')"
    shopt -s nullglob
    for meta in "$CONF_DIR"/fwd-*.meta; do
        proto=$(sed -n 's/^proto=//p' "$meta")
        dest=$(sed -n 's/^dest=//p' "$meta")
        count=$(sed -n 's/^count=//p' "$meta")
        # fwd-3.meta -> gost-fwd-3.service
        unit="gost-fwd-${meta##*/fwd-}"
        unit="${unit%.meta}.service"
        # is-active prints its own state AND exits non-zero when inactive; do not append "|| echo" to it.
        state=$(systemctl is-active "$unit" 2>/dev/null) || true
        printf '  %-22s %-8s -> %-40s %s ports  [%s]\n' \
            "$unit" "$proto" "$dest" "$count" "${state:-unknown}"
    done
    shopt -u nullglob
    if ls /usr/lib/systemd/system/gost_*.service >/dev/null 2>&1 || ls /etc/systemd/system/gost_*.service >/dev/null 2>&1; then
        warn "Legacy gost_*.service units still exist. Run the install once with \"replace all existing forwards\"."
    fi
    echo
}

# The generated script must contain the real unit path. An earlier version used a quoted
# heredoc, so ${UNIT_DIR} stayed literal, expanded to nothing, and the cron job did nothing.
write_restart_script(){
    cat > "$RESTART_SCRIPT" <<EOF
#!/usr/bin/env bash
shopt -s nullglob
units=(${UNIT_DIR}/gost-fwd-*.service)
[ "\${#units[@]}" -gt 0 ] || exit 0
systemctl restart "\${units[@]##*/}"
EOF
    chmod 755 "$RESTART_SCRIPT"
}

remove_cron_entry(){
    command -v crontab >/dev/null 2>&1 || return 0
    crontab -l 2>/dev/null | grep -vF "$RESTART_SCRIPT" | crontab - 2>/dev/null || true
}

schedule_restart(){
    local h action
    echo "  1) Enable"
    echo "  2) Disable"
    read -r -p "Choice: " action || die "Input closed."
    case "$action" in
        2)
            remove_cron_entry
            rm -f "$RESTART_SCRIPT"
            ok "Scheduled restart removed."
            return 0
            ;;
        1) ;;
        *) warn "Cancelled."; return 0 ;;
    esac
    command -v crontab >/dev/null 2>&1 || die "crontab is not installed (apt install cron)."
    read -r -p "Restart every how many hours? (1-23): " h || die "Input closed."
    [[ "$h" =~ ^[0-9]+$ ]] || die "Invalid number of hours."
    h=$(( 10#$h ))
    [ "$h" -ge 1 ] && [ "$h" -le 23 ] || die "Invalid number of hours."
    write_restart_script
    (crontab -l 2>/dev/null | grep -vF "$RESTART_SCRIPT" || true
     echo "0 */${h} * * * ${RESTART_SCRIPT}") | crontab - || die "Could not install the cron job."
    ok "Gost will be restarted every ${h} hours."
}

remove_net_rules(){
    local ipt
    for ipt in iptables ip6tables; do
        command -v "$ipt" >/dev/null 2>&1 || continue
        while "$ipt" -t mangle -D POSTROUTING -j "$CHAIN" 2>/dev/null; do :; done
        "$ipt" -t mangle -F "$CHAIN" 2>/dev/null || true
        "$ipt" -t mangle -X "$CHAIN" 2>/dev/null || true
    done
}

uninstall_all(){
    local yn
    read -r -p "Remove Gost and all forwards? [y/N] " yn || die "Input closed."
    [ "$yn" = "y" ] || [ "$yn" = "Y" ] || { ok "Cancelled."; return 0; }
    remove_legacy_units
    remove_cron_entry
    rm -f "$RESTART_SCRIPT" "$BIN" "${BIN}.new" "$MENU_BIN"
    rm -f "$SYSCTL_PORTS"
    rmdir "$CONF_DIR" 2>/dev/null || true
    systemctl daemon-reload || true
    read -r -p "Remove the kernel optimizer settings too? [y/N] " yn || die "Input closed."
    if [ "$yn" = "y" ] || [ "$yn" = "Y" ]; then
        systemctl disable --now tunnel-net-tweaks.service >/dev/null 2>&1 || true
        rm -f "$NET_UNIT" "$NET_SCRIPT" "$SYSCTL_MAIN" "$LIMITS_CONF" "$SYSTEMD_LIMITS_CONF"
        remove_net_rules
        systemctl daemon-reload || true
        sysctl --system >/dev/null 2>&1 || true
        warn "Already-applied sysctl values stay active until the next reboot."
    fi
    ok "Removed."
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
    local kind=$1 yn n
    choose_and_install
    ask_ip "$kind"
    ask_ports
    ask_proto
    n=$(port_count)
    echo
    info "Destination: ${DEST_IP}   Protocol: ${PROTO}   Ports: ${n}"
    if has_forwards; then
        echo "  1) Replace all existing forwards"
        echo "  2) Add to the existing forwards"
        read -r -p "Choice [2]: " yn || die "Input closed."
        if [ "${yn:-2}" = 1 ]; then write_forward "$DEST_IP" "$PROTO" 1
        else write_forward "$DEST_IP" "$PROTO" 0
        fi
    else
        write_forward "$DEST_IP" "$PROTO" 1
    fi
    read -r -p "Apply the tunnel optimizer too? [Y/n] " yn || die "Input closed."
    if [ "${yn:-Y}" = "Y" ] || [ "${yn:-Y}" = "y" ]; then
        optimize_server
    fi
    show_status
}

add_forward(){
    local ipkind
    [ -x "$BIN" ] || die "Create a tunnel first (menu 1 or 2)."
    echo "  1) IPv4    2) IPv6"
    read -r -p "Destination IP type [1]: " ipkind || die "Input closed."
    case "${ipkind:-1}" in
        1) ask_ip 4 ;;
        2) ask_ip 6 ;;
        *) die "Invalid choice." ;;
    esac
    ask_ports
    ask_proto
    write_forward "$DEST_IP" "$PROTO" 0
    show_status
}

# Run a menu action in a subshell: die() then only aborts that action, not the whole menu.
run_action(){ ( "$@" ); }

menu(){
    local choice
    while true; do
        echo
        printf '%sGost Tunnel + Optimizer%s\n' "$B" "$N"
        echo "  1) Tunnel to a foreign IPv4"
        echo "  2) Tunnel to a foreign IPv6"
        echo "  3) Status"
        echo "  4) Add a port or an IP"
        echo "  5) Install or change the Gost version"
        echo "  6) Scheduled restart"
        echo "  7) Optimize the tunnel server"
        echo "  8) Uninstall"
        echo "  0) Exit"
        read -r -p "Choice: " choice || { echo; exit 0; }
        case "$choice" in
            1) run_action create_tunnel 4 ;;
            2) run_action create_tunnel 6 ;;
            3) show_status ;;
            4) run_action add_forward ;;
            5) run_action choose_and_install ;;
            6) run_action schedule_restart ;;
            7) run_action optimize_server; show_status ;;
            8) run_action uninstall_all ;;
            0) exit 0 ;;
            *) warn "Enter a number from the menu." ;;
        esac
    done
}

self_test(){
    local tmp=${1:-}
    [ -n "$tmp" ] || tmp=$(mktemp -d) || die "mktemp failed"
    CONF_DIR=$tmp/conf
    UNIT_DIR=$tmp/units
    SYSCTL_PORTS=$tmp/ports.conf
    RESTART_SCRIPT=$tmp/restart.sh
    BIN=/bin/true
    mkdir -p "$CONF_DIR" "$UNIT_DIR" "$tmp/bin"
    # Mock everything that touches the real system. Without the sysctl mock, a root
    # self-test really rewrites ip_local_reserved_ports on the live kernel.
    systemctl(){ return 0; }
    sysctl(){ return 0; }
    gost_major(){ echo 3; }

    # --- parsing ---
    parse_port_spec "443,2053,1000-1002" 0 || die "parse list failed"
    [ "$(port_count)" -eq 5 ] || die "count want 5 got $(port_count)"
    parse_port_spec "54,80" 1 || die "parse old range failed"
    [ "${STARTS[0]}" = 54 ] && [ "${ENDS[0]}" = 80 ] || die "old range not expanded"
    parse_port_spec "0443" 0 || die "leading zero rejected"
    [ "${STARTS[0]}" = 443 ] || die "leading zero parsed as octal: ${STARTS[0]}"
    parse_port_spec "0899" 0 || die "0899 rejected (invalid octal?)"
    [ "${STARTS[0]}" = 899 ] || die "0899 wrong: ${STARTS[0]}"
    parse_port_spec "70000-70001" 0 2>/dev/null && die "high port should fail"
    parse_port_spec "10-5" 0 2>/dev/null && die "reverse range should fail"
    parse_port_spec "443,443" 0 2>/dev/null && die "duplicate port should fail"
    parse_port_spec "100-200,150" 0 2>/dev/null && die "overlap inside one input should fail"
    parse_port_spec "443," 0 2>/dev/null && die "trailing comma should fail"
    parse_port_spec "1,,2" 0 2>/dev/null && die "empty item should fail"

    # --- addresses ---
    is_ipv4 1.2.3.4 || die "ipv4"
    is_ipv4 1.2.3.256 && die "ipv4 octet"
    is_ipv4 01.2.3.4 && die "ipv4 leading zero"
    is_ipv6 2001:db8::1 || die "ipv6"
    is_ipv6 ::1 || die "ipv6 ::1"
    is_ipv6 :: || die "ipv6 ::"
    is_ipv6 1:2:3:4:5:6:7:8 || die "ipv6 full"
    is_ipv6 1.2.3.4 && die "ipv4 detected as ipv6"
    is_ipv6 ":::" && die "ipv6 :::"
    is_ipv6 "1:2:3" && die "ipv6 too short"
    is_ipv6 "2001:db8::1::2" && die "ipv6 double ::"
    is_ipv6 "1:2:3:4:5:6:7:8:" && die "ipv6 trailing colon"
    is_ipv6 "12345::1" && die "ipv6 group too long"
    is_ipv6 "1:2:3:4:5:6:7:8::" && die "ipv6 too many groups"
    [ "$(dest_host 2001:db8::1)" = "[2001:db8::1]" ] || die "bracket"
    [ "$(dest_host 1.2.3.4)" = "1.2.3.4" ] || die "v4 host"

    # --- version detection ---
    [ "$(major_from_version_line 'gost 2.11.5 (go1.13.3 linux/amd64)')" = 2 ] || die "v2 line with go1.13.3 misdetected"
    [ "$(major_from_version_line 'gost 3.3.3 (go1.27.3 linux/amd64)')" = 3 ] || die "v3 line"
    [ "$(major_from_version_line 'something else 3.0')" = 0 ] || die "garbage line"

    # --- generated v3 config, chunking, reserved ports ---
    CHUNK=2
    STARTS=(443 1000)
    ENDS=(444 1001)
    write_forward 2001:db8::1 udp 0 >/dev/null
    grep -q '\[2001:db8::1\]:443' "$CONF_DIR/fwd-0.yaml" || die "yaml missing ipv6 brackets"
    grep -q '^    metadata:' "$CONF_DIR/fwd-0.yaml" || die "udp metadata not under listener"
    grep -q 'LimitNOFILE=1048576' "$UNIT_DIR/gost-fwd-0.service" || die "nofile"
    grep -q 'fwd-0.yaml' "$UNIT_DIR/gost-fwd-0.service" || die "unit config path"
    [ -f "$UNIT_DIR/gost-fwd-1.service" ] || die "chunk was not split"
    grep -q '443-444,1000-1001' "$SYSCTL_PORTS" || die "reserved ports: $(cat "$SYSCTL_PORTS")"
    overlaps_used 444 444 2>/dev/null || die "overlap was not recorded"
    overlaps_used 2000 2001 && die "false overlap"
    [ "$(next_index)" -eq 2 ] || die "next_index want 2 got $(next_index)"
    rm -f "$UNIT_DIR/gost-fwd-0.service"          # leave a gap: only index 1 remains
    [ "$(next_index)" -eq 2 ] || die "next_index must use max+1 when there is a gap"

    # --- v2 JSON ---
    rm -rf "$CONF_DIR" "$UNIT_DIR"
    mkdir -p "$CONF_DIR" "$UNIT_DIR"
    gost_major(){ echo 2; }
    CHUNK=1500
    STARTS=(80)
    ENDS=(80)
    write_forward 1.2.3.4 tcp 0 >/dev/null
    grep -q 'tcp://:80/1.2.3.4:80' "$CONF_DIR/fwd-0.json" || die "v2 node"
    if command -v python3 >/dev/null 2>&1; then
        python3 -m json.tool "$CONF_DIR/fwd-0.json" >/dev/null || die "v2 json invalid"
    fi
    grep -q 'fwd-0.json' "$UNIT_DIR/gost-fwd-0.service" || die "v2 unit config path"
    ( write_forward 1.2.3.4 grpc 0 ) 2>/dev/null && die "grpc must be rejected on v2"

    # --- v3 grpc ---
    rm -rf "$CONF_DIR" "$UNIT_DIR"
    mkdir -p "$CONF_DIR" "$UNIT_DIR"
    gost_major(){ echo 3; }
    STARTS=(90)
    ENDS=(90)
    write_forward 8.8.8.8 grpc 0 >/dev/null
    grep -q 'type: grpc' "$CONF_DIR/fwd-0.yaml" || die "grpc listener"
    grep -q 'type: tcp' "$CONF_DIR/fwd-0.yaml" || die "grpc handler"

    # --- scheduled restart script: must contain the real path and actually work ---
    printf '#!/bin/sh\necho "$@" >> %s/systemctl.log\n' "$tmp" > "$tmp/bin/systemctl"
    chmod 755 "$tmp/bin/systemctl"
    write_restart_script
    grep -q "units=(${UNIT_DIR}/gost-fwd-\*.service)" "$RESTART_SCRIPT" || die "restart script lost the unit path: $(cat "$RESTART_SCRIPT")"
    PATH="$tmp/bin:$PATH" bash "$RESTART_SCRIPT"
    grep -q 'restart gost-fwd-0.service' "$tmp/systemctl.log" || die "restart script did not restart the unit"

    rm -rf "$tmp"
    ok "self-test passed"
}

case "${1:-}" in
    --self-test) self_test "${2:-}"; exit 0 ;;
    --optimize) need_root; optimize_server; exit 0 ;;
    --status) show_status; exit 0 ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    "") ;;
    *) die "Unknown argument: $1" ;;
esac

need_root
install_menu_cmd
menu
