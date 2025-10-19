#!/bin/bash
set -e

# Переменные окружения
ZT_NETWORK=${ZT_NETWORK:-""}
PORT_FORWARD=${PORT_FORWARD:-""}
GATEWAY_MODE=${GATEWAY_MODE:-"false"}
ALLOWED_SOURCES=${ALLOWED_SOURCES:-"any"}
FORCE_ZEROTIER_ROUTES=${FORCE_ZEROTIER_ROUTES:-""}

# Simple resolver: use getent (NSS: /etc/hosts + Docker DNS + DNS) then ping as fallback.
resolve_name_to_ip() {
    local name="$1"
    local ip=""

    # if already IPv4
    if [[ "$name" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$name"
        return 0
    fi

    if command -v getent >/dev/null 2>&1; then
        ip=$(getent hosts "$name" | awk '{print $1; exit}' || true)
        if [ -n "$ip" ]; then
            echo "$ip"
            return 0
        fi
    fi

    # fallback to ping (least preferred)
    if command -v ping >/dev/null 2>&1; then
        ip=$(ping -c1 "$name" 2>/dev/null | head -1 | awk -F'[()]' '{print $2}' || true)
        if [ -n "$ip" ]; then
            echo "$ip"
            return 0
        fi
    fi

    return 1
}

# DNS Configuration: Docker manages /etc/resolv.conf automatically with embedded DNS.
# We only add a public DNS fallback for ZeroTier planet lookups (external DNS queries).
echo "Configuring DNS..."
if [ -f /etc/resolv.conf ] && grep -qE '^nameserver' /etc/resolv.conf 2>/dev/null; then
    echo "Current DNS config:"
    cat /etc/resolv.conf | grep nameserver

    # Add Google DNS as fallback if not present (for ZeroTier external lookups)
    if ! grep -q '8.8.8.8' /etc/resolv.conf 2>/dev/null; then
        echo 'nameserver 8.8.8.8' >> /etc/resolv.conf
        echo "Added 8.8.8.8 as fallback DNS"
    fi
else
    echo "⚠️  Warning: /etc/resolv.conf is empty or missing"
fi

echo "Starting ZeroTier sidecar..."
echo "Mode: $GATEWAY_MODE"
echo "ZeroTier network: $ZT_NETWORK"
echo "Port forwarding: $PORT_FORWARD"
if [ -n "$FORCE_ZEROTIER_ROUTES" ]; then
    echo "Custom routes: $FORCE_ZEROTIER_ROUTES"
fi

# Pre-resolve any container/service names in PORT_FORWARD before we start
# ZeroTier. Docker embedded DNS (127.0.0.11) can stop responding after we
# change network namespaces, so try to resolve names early and replace them
# with IPs in PORT_FORWARD where possible.
pre_resolve_port_forward() {
    if [ -z "$PORT_FORWARD" ]; then
        return 0
    fi

    local new_forwards=""
    IFS=',' read -ra _FORW <<< "$PORT_FORWARD"
    for f in "${_FORW[@]}"; do
        IFS=':' read -ra P <<< "$f"
        EXT=${P[0]}
        DST=${P[1]}
        DPT=${P[2]}

        if [[ -z "$EXT" || -z "$DST" || -z "$DPT" ]]; then
            continue
        fi

        if [[ "$DST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            new_forwards+="$EXT:$DST:$DPT,"
            continue
        fi

        if ipaddr=$(resolve_name_to_ip "$DST"); then
            echo "(pre-resolve) $DST -> $ipaddr"
            new_forwards+="$EXT:$ipaddr:$DPT,"
        else
            new_forwards+="$EXT:$DST:$DPT,"
        fi
    done

    new_forwards=${new_forwards%,}
    if [ -n "$new_forwards" ]; then
        PORT_FORWARD="$new_forwards"
        echo "PORT_FORWARD updated (pre-resolve): $PORT_FORWARD"
    fi
}

pre_resolve_port_forward

# Функция настройки firewall
setup_firewall() {
    echo "Setting up firewall rules..."

    # ВАЖНО: НЕ очищаем существующие правила Docker!
    # Docker создает правила для embedded DNS (127.0.0.11) и bridge сетей.
    # Полная очистка iptables -F и -t nat -F ломает Docker DNS!
    # Вместо этого используем -I (INSERT) для добавления правил в начало цепочек.

    # Создаем свою цепочку для ZeroTier правил (если еще не существует)
    iptables -N ZEROTIER_INPUT 2>/dev/null || true
    iptables -N ZEROTIER_FORWARD 2>/dev/null || true

    # Очищаем только наши цепочки
    iptables -F ZEROTIER_INPUT 2>/dev/null || true
    iptables -F ZEROTIER_FORWARD 2>/dev/null || true

    # Направляем трафик в наши цепочки (в начало, чтобы обрабатывались первыми)
    iptables -I INPUT -j ZEROTIER_INPUT 2>/dev/null || iptables -D INPUT -j ZEROTIER_INPUT 2>/dev/null; iptables -I INPUT -j ZEROTIER_INPUT
    iptables -I FORWARD -j ZEROTIER_FORWARD 2>/dev/null || iptables -D FORWARD -j ZEROTIER_FORWARD 2>/dev/null; iptables -I FORWARD -j ZEROTIER_FORWARD

    # Разрешаем loopback (критично для Docker embedded DNS!)
    iptables -A ZEROTIER_INPUT -i lo -j ACCEPT

    # Разрешаем established соединения
    iptables -A ZEROTIER_INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -A ZEROTIER_FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

    # Разрешаем ICMP (ping) на контейнер
    iptables -A ZEROTIER_INPUT -p icmp --icmp-type echo-request -j ACCEPT
    iptables -A ZEROTIER_FORWARD -p icmp -j ACCEPT

    # Всегда разрешаем ZeroTier UDP
    iptables -A ZEROTIER_INPUT -p udp --dport 9993 -j ACCEPT

    # Защита от сканирования портов
    iptables -A ZEROTIER_INPUT -p tcp --tcp-flags ALL NONE -j DROP
    iptables -A ZEROTIER_INPUT -p tcp --tcp-flags ALL ALL -j DROP
    iptables -A ZEROTIER_INPUT -p tcp --tcp-flags SYN,FIN SYN,FIN -j DROP
    iptables -A ZEROTIER_INPUT -p tcp --tcp-flags SYN,RST SYN,RST -j DROP

    echo "✓ ZeroTier firewall rules applied (Docker rules preserved)"
}

# Функция для получения интерфейса по которому идет трафик к IP
get_interface_for_ip() {
    local dest_ip="$1"
    local route_info
    route_info=$(ip route get "$dest_ip" 2>/dev/null)
    
    if [ $? -eq 0 ]; then
        local interface
        interface=$(echo "$route_info" | grep -o 'dev [^ ]*' | awk '{print $2}')
        echo "$interface"
    else
        echo ""
    fi
}

# Функция для получения активных Docker сетей
get_docker_networks() {
    # Получаем маршруты и фильтруем Docker сети
    ip route show | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+' | while read -r route; do
        network=$(echo "$route" | awk '{print $1}')
        interface=$(echo "$route" | awk '{print $3}')
        
        # Исключаем ZeroTier интерфейс и localhost
        if [ "$interface" != "$ZT_IF" ] && [ "$interface" != "lo" ] && [[ "$interface" =~ ^(eth|br-|docker) ]]; then
            echo "$network"
        fi
    done | sort -u
}

# Функция добавления правил для Docker сетей
add_docker_network_rules() {
    local port="$1"

    get_docker_networks | while read -r network; do
        if [ -n "$network" ]; then
            echo "Adding Docker network rule: $network -> port $port"
            iptables -I ZEROTIER_INPUT -s "$network" -p tcp --dport "$port" -j ACCEPT
        fi
    done
}

# Функция проверки попадания IP в сеть
ip_in_network() {
    local ip="$1"
    local network="$2"
    
    # Проверка для /24 сетей
    if [[ "$network" == *"/24" ]]; then
        local network_base=${network%.*}
        local ip_base=${ip%.*}
        if [ "$network_base" = "$ip_base" ]; then
            return 0
        fi
    fi
    
    # Проверка для /16 сетей  
    if [[ "$network" == *"/16" ]]; then
        local network_base=${network%.*.*}
        local ip_base=${ip%.*.*}
        if [ "$network_base" = "$ip_base" ]; then
            return 0
        fi
    fi
    
    return 1
}

# Функция для определения типа сети
is_zerotier_address() {
    local dest_ip="$1"
    
    # ШАГ 1: Стандартная проверка интерфейса
    local interface
    interface=$(get_interface_for_ip "$dest_ip")
    
    echo "Checking route for $dest_ip -> interface: $interface"
    
    # Определяем тип по интерфейсу
    local is_zt_by_interface=false
    if [[ "$interface" =~ ^zt ]]; then
        is_zt_by_interface=true
        echo "Interface detection: ZeroTier address $dest_ip (interface: $interface)"
    else
        echo "Interface detection: local/Docker address $dest_ip (interface: $interface)"
    fi
    
    # ШАГ 2: Кастомные маршруты переопределяют результат
    if [ -n "$FORCE_ZEROTIER_ROUTES" ]; then
        IFS=',' read -ra ROUTES <<< "$FORCE_ZEROTIER_ROUTES"
        for route_rule in "${ROUTES[@]}"; do
            IFS=':' read -ra ROUTE_PARTS <<< "$route_rule"
            local network=${ROUTE_PARTS[0]}
            
            if [ -n "$network" ]; then
                if ip_in_network "$dest_ip" "$network"; then
                    echo "Custom route override: $dest_ip -> ZeroTier (network: $network)"
                    return 0
                fi
            fi
        done
    fi
    
    # ШАГ 3: Возвращаем результат стандартной проверки
    if [ "$is_zt_by_interface" = true ]; then
        echo "Final result: ZeroTier address"
        return 0
    else
        echo "Final result: Docker/local address"
        return 1
    fi
}

# Функция применения кастомных маршрутов
apply_custom_routes() {
    if [ -n "$FORCE_ZEROTIER_ROUTES" ]; then
        echo "Applying custom ZeroTier routes..."
        IFS=',' read -ra ROUTES <<< "$FORCE_ZEROTIER_ROUTES"
        for route_rule in "${ROUTES[@]}"; do
            IFS=':' read -ra ROUTE_PARTS <<< "$route_rule"
            local network=${ROUTE_PARTS[0]}
            local gateway=${ROUTE_PARTS[1]}
            
            if [ -n "$network" ] && [ -n "$gateway" ]; then
                echo "Adding route: $network via $gateway dev $ZT_IF"
                ip route add "$network" via "$gateway" dev "$ZT_IF" 2>/dev/null || true
            fi
        done
        echo "✓ Custom routes applied"
    fi
}

# Проверяем интернет подключение
echo "Testing internet connectivity..."
if ping -c 3 8.8.8.8 >/dev/null 2>&1; then
    echo "✓ Internet connectivity OK"
else
    echo "✗ No internet connectivity - checking network..."
    ip route
fi

# Запускаем ZeroTier
echo "Starting ZeroTier daemon..."
zerotier-one &

# Ждём появления zerotier-cli
echo "Waiting for ZeroTier CLI..."
until command -v zerotier-cli >/dev/null 2>&1; do
    sleep 1
done

# Ждём готовности демона
echo "Waiting for ZeroTier daemon..."
attempt=0
while [ $attempt -lt 30 ]; do
    if zerotier-cli info >/dev/null 2>&1; then
        echo "ZeroTier daemon ready"
        break
    fi
    sleep 2
    attempt=$((attempt+1))
done

# Присоединяемся к сети (поддержка нескольких сетей через запятую)
if [ -n "$ZT_NETWORK" ]; then
    echo "Joining ZeroTier network(s): $ZT_NETWORK"
    IFS=',' read -ra NETWORKS <<< "$ZT_NETWORK"
    for network in "${NETWORKS[@]}"; do
        network=$(echo "$network" | xargs)  # Trim whitespace
        if [ -n "$network" ]; then
            echo "Joining network: $network"
            zerotier-cli join "$network"
        fi
    done

    sleep 2
    echo "Network status:"
    zerotier-cli listnetworks
fi

# Подсчитываем количество сетей
IFS=',' read -ra NETWORKS <<< "$ZT_NETWORK"
EXPECTED_NETWORKS=${#NETWORKS[@]}
echo "Expected ZeroTier networks: $EXPECTED_NETWORKS"

# Ждём появления всех интерфейсов
echo "Waiting for ZeroTier interface(s)..."
attempt=0
while [ $attempt -lt 60 ]; do
    # Получаем все ZeroTier интерфейсы
    ZT_INTERFACES=($(ip -o link | awk -F': ' '/zt/ {print $2}'))
    CURRENT_COUNT=${#ZT_INTERFACES[@]}

    if [ $CURRENT_COUNT -ge $EXPECTED_NETWORKS ]; then
        echo "Found $CURRENT_COUNT ZeroTier interface(s): ${ZT_INTERFACES[*]}"
        break
    fi

    echo "Waiting for interfaces... ($CURRENT_COUNT/$EXPECTED_NETWORKS)"
    sleep 2
    attempt=$((attempt+1))
done

if [ ${#ZT_INTERFACES[@]} -eq 0 ]; then
    echo "✗ No ZeroTier interfaces found"
    exit 1
fi

# Для обратной совместимости: ZT_IF = первый интерфейс
ZT_IF="${ZT_INTERFACES[0]}"
echo "Primary ZeroTier interface: $ZT_IF"

# Ждём присвоения IP на всех интерфейсах
echo "Waiting for IP assignment on all interfaces..."
attempt=0
ALL_IPS_ASSIGNED=false

while [ $attempt -lt 60 ]; do
    ALL_IPS_ASSIGNED=true
    ZT_IPS=()

    for iface in "${ZT_INTERFACES[@]}"; do
        iface_ip=$(ip -o -4 addr show dev "$iface" 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
        if [ -n "$iface_ip" ]; then
            ZT_IPS+=("$iface:$iface_ip")
        else
            ALL_IPS_ASSIGNED=false
            echo "Waiting for IP on $iface..."
        fi
    done

    if [ "$ALL_IPS_ASSIGNED" = true ] && [ ${#ZT_IPS[@]} -ge $EXPECTED_NETWORKS ]; then
        echo "All IPs assigned:"
        for ip_info in "${ZT_IPS[@]}"; do
            echo "  $ip_info"
        done
        break
    fi

    sleep 2
    attempt=$((attempt+1))
done

if [ "$ALL_IPS_ASSIGNED" != true ]; then
    echo "⚠️  Warning: Not all interfaces have IP addresses assigned"
fi

# Для обратной совместимости: ZT_IP = IP первого интерфейса
ZT_IP=$(ip -o -4 addr show dev "$ZT_IF" 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
if [ -z "$ZT_IP" ]; then
    echo "✗ Failed to get ZeroTier IP for primary interface"
    exit 1
fi
echo "Primary ZeroTier IP: $ZT_IP"

# Включаем IP форвардинг
echo "Enabling IP forwarding..."
sysctl -w net.ipv4.ip_forward=1

# Настраиваем firewall (создает цепочки ZEROTIER_INPUT и ZEROTIER_FORWARD)
setup_firewall

# Применяем кастомные маршруты
apply_custom_routes

# Разрешаем трафик на ZeroTier интерфейсах для hybrid/gateway режимов
if [ "$GATEWAY_MODE" = "hybrid" ] || [ "$GATEWAY_MODE" = "true" ]; then
    echo "Adding ZeroTier interface rules for $GATEWAY_MODE mode..."

    # Проверяем что цепочки существуют
    if ! iptables -L ZEROTIER_INPUT -n >/dev/null 2>&1; then
        echo "⚠️  Warning: ZEROTIER_INPUT chain not found, creating..."
        iptables -N ZEROTIER_INPUT
        iptables -I INPUT -j ZEROTIER_INPUT
    fi

    if ! iptables -L ZEROTIER_FORWARD -n >/dev/null 2>&1; then
        echo "⚠️  Warning: ZEROTIER_FORWARD chain not found, creating..."
        iptables -N ZEROTIER_FORWARD
        iptables -I FORWARD -j ZEROTIER_FORWARD
    fi

    # Добавляем правила для всех ZeroTier интерфейсов
    for zt_iface in "${ZT_INTERFACES[@]}"; do
        echo "Adding rules for interface: $zt_iface"
        iptables -I ZEROTIER_INPUT -i "$zt_iface" -j ACCEPT

        # Разрешаем форвардинг между всеми ZeroTier интерфейсами
        for zt_iface2 in "${ZT_INTERFACES[@]}"; do
            iptables -I ZEROTIER_FORWARD -i "$zt_iface" -o "$zt_iface2" -j ACCEPT
        done
    done

    echo "✓ ZeroTier internal traffic allowed on ${#ZT_INTERFACES[@]} interface(s)"
fi

# Диагностика DNS после настройки firewall
echo ""
echo "=== DNS Diagnostics ==="
echo "DNS configuration:"
cat /etc/resolv.conf | grep nameserver || echo "⚠️  No nameservers found!"

echo ""
echo "Testing DNS resolution:"
# Test Docker embedded DNS (if available)
if grep -q '127.0.0.11' /etc/resolv.conf 2>/dev/null; then
    echo -n "Docker embedded DNS (127.0.0.11): "
    if nslookup -timeout=2 google.com 127.0.0.11 >/dev/null 2>&1; then
        echo "✓ Working"
    else
        echo "✗ Not responding"
    fi
fi

# Test external DNS
echo -n "External DNS resolution: "
if nslookup -timeout=2 google.com >/dev/null 2>&1; then
    echo "✓ Working"
else
    echo "✗ Failed"
fi

# Test Docker network DNS (try to resolve common Docker service names)
echo -n "Docker service name resolution: "
if getent hosts host.docker.internal >/dev/null 2>&1; then
    echo "✓ host.docker.internal resolves"
elif getent hosts gateway.docker.internal >/dev/null 2>&1; then
    echo "✓ gateway.docker.internal resolves"
else
    echo "ℹ️  No standard Docker hostnames detected (this is OK if no services defined)"
fi

echo "======================="
echo ""

echo "=== Firewall Status ==="
echo "Active iptables chains:"
iptables -L -n | grep -E '^Chain (DOCKER|ZEROTIER_|INPUT|FORWARD)' | head -10

echo ""
echo "Docker NAT rules (sample):"
iptables -t nat -L DOCKER -n 2>/dev/null | head -5 || echo "ℹ️  DOCKER chain not found (OK if no containers in bridge network)"

echo ""
echo "ZeroTier custom rules:"
iptables -L ZEROTIER_INPUT -n 2>/dev/null | head -8 || echo "⚠️  ZEROTIER_INPUT chain missing"
echo "======================="
echo ""

# Настройка правил для проброса портов — сначала один раз резолвим имена
if [ -n "$PORT_FORWARD" ]; then
    echo "Resolving port forwarding destinations..."
    RESOLVED_FORWARDS=""
    IFS=',' read -ra FORWARDS <<< "$PORT_FORWARD"
    for forward in "${FORWARDS[@]}"; do
        IFS=':' read -ra PARTS <<< "$forward"
        EXT_PORT=${PARTS[0]}
        RAW_DEST=${PARTS[1]}
        DEST_PORT=${PARTS[2]}

        if [ -z "$EXT_PORT" ] || [ -z "$RAW_DEST" ] || [ -z "$DEST_PORT" ]; then
            continue
        fi

        RESOLVED_IP=""
        if RESOLVED_IP=$(resolve_name_to_ip "$RAW_DEST"); then
            echo "Resolved $RAW_DEST -> $RESOLVED_IP"
            RESOLVED_FORWARDS+="${EXT_PORT}:${RESOLVED_IP}:${DEST_PORT},"
        else
            echo "✗ Cannot resolve destination: $RAW_DEST. Skipping rule $EXT_PORT:$RAW_DEST:$DEST_PORT"
        fi
    done

    # Trim trailing comma
    RESOLVED_FORWARDS=${RESOLVED_FORWARDS%,}

    if [ -z "$RESOLVED_FORWARDS" ]; then
        echo "No valid port forwards after resolution"
    else
        echo "Setting up port forwarding..."
        IFS=',' read -ra FORWARDS <<< "$RESOLVED_FORWARDS"
        for forward in "${FORWARDS[@]}"; do
            IFS=':' read -ra PARTS <<< "$forward"
            EXT_PORT=${PARTS[0]}
            DEST_IP=${PARTS[1]}
            DEST_PORT=${PARTS[2]}

            if [ -n "$EXT_PORT" ] && [ -n "$DEST_IP" ] && [ -n "$DEST_PORT" ]; then
                echo "Setting up: $EXT_PORT -> $DEST_IP:$DEST_PORT"

                # Открываем порты в зависимости от режима
                case $GATEWAY_MODE in
                    "false")
                        echo "Backend mode: opening port $EXT_PORT on ZeroTier interfaces only"
                        for zt_iface in "${ZT_INTERFACES[@]}"; do
                            iptables -I ZEROTIER_INPUT -i "$zt_iface" -p tcp --dport $EXT_PORT -j ACCEPT
                        done
                        ;;
                    "true")
                        echo "Gateway mode: opening port $EXT_PORT for external access"
                        if [ "$ALLOWED_SOURCES" != "any" ]; then
                            IFS=',' read -ra SOURCES <<< "$ALLOWED_SOURCES"
                            for source in "${SOURCES[@]}"; do
                                iptables -I ZEROTIER_INPUT -s "$source" -p tcp --dport $EXT_PORT -j ACCEPT
                            done
                        else
                            iptables -I ZEROTIER_INPUT -p tcp --dport $EXT_PORT -j ACCEPT
                        fi
                        add_docker_network_rules "$EXT_PORT"
                        ;;
                    "hybrid")
                        echo "Hybrid mode: opening port $EXT_PORT on all interfaces"
                        if [ "$ALLOWED_SOURCES" != "any" ]; then
                            IFS=',' read -ra SOURCES <<< "$ALLOWED_SOURCES"
                            for source in "${SOURCES[@]}"; do
                                iptables -I ZEROTIER_INPUT -s "$source" -p tcp --dport $EXT_PORT -j ACCEPT
                            done
                        else
                            iptables -I ZEROTIER_INPUT -p tcp --dport $EXT_PORT -j ACCEPT
                        fi
                        for zt_iface in "${ZT_INTERFACES[@]}"; do
                            iptables -I ZEROTIER_INPUT -i "$zt_iface" -p tcp --dport $EXT_PORT -j ACCEPT
                        done
                        add_docker_network_rules "$EXT_PORT"
                        ;;
                    *)
                        echo "Invalid GATEWAY_MODE: $GATEWAY_MODE. Use: false, true, or hybrid"
                        exit 1
                        ;;
                esac

                # Выбираем способ перенаправления
                if is_zerotier_address "$DEST_IP"; then
                    echo "Destination is ZeroTier address, using socat proxy"
                    if [ "$GATEWAY_MODE" = "true" ] || [ "$GATEWAY_MODE" = "hybrid" ]; then
                        echo "Starting socat proxy: $EXT_PORT -> $DEST_IP:$DEST_PORT"
                        socat TCP-LISTEN:$EXT_PORT,bind=0.0.0.0,fork,reuseaddr TCP:$DEST_IP:$DEST_PORT &
                        echo "✓ Socat proxy started for port $EXT_PORT"
                    fi
                else
                    echo "Destination is local Docker address, using iptables DNAT"
                    if [ "$GATEWAY_MODE" = "false" ] || [ "$GATEWAY_MODE" = "hybrid" ]; then
                        DEST_INTERFACE=$(get_interface_for_ip "$DEST_IP")

                        # Создаём DNAT правила для всех ZeroTier интерфейсов
                        for zt_iface in "${ZT_INTERFACES[@]}"; do
                            echo "Adding DNAT rule for interface: $zt_iface"
                            iptables -t nat -A PREROUTING -i "$zt_iface" -p tcp --dport $EXT_PORT -j DNAT --to-destination $DEST_IP:$DEST_PORT

                            if [ -n "$DEST_INTERFACE" ]; then
                                iptables -A FORWARD -i "$zt_iface" -o "$DEST_INTERFACE" -p tcp -d $DEST_IP --dport $DEST_PORT -j ACCEPT
                                iptables -A FORWARD -i "$DEST_INTERFACE" -o "$zt_iface" -p tcp -s $DEST_IP --sport $DEST_PORT -j ACCEPT
                            else
                                echo "⚠️  Could not determine interface for $DEST_IP, using eth0"
                                iptables -A FORWARD -i "$zt_iface" -o eth0 -p tcp -d $DEST_IP --dport $DEST_PORT -j ACCEPT
                                iptables -A FORWARD -i eth0 -o "$zt_iface" -p tcp -s $DEST_IP --sport $DEST_PORT -j ACCEPT
                            fi
                        done

                        # MASQUERADE правило нужно только одно (не зависит от входящего интерфейса)
                        if [ -n "$DEST_INTERFACE" ]; then
                            iptables -t nat -A POSTROUTING -o "$DEST_INTERFACE" -p tcp -d $DEST_IP --dport $DEST_PORT -j MASQUERADE
                            echo "✓ iptables DNAT configured for $DEST_IP via interface $DEST_INTERFACE (${#ZT_INTERFACES[@]} ZeroTier interfaces)"
                        else
                            iptables -t nat -A POSTROUTING -o eth0 -p tcp -d $DEST_IP --dport $DEST_PORT -j MASQUERADE
                            echo "✓ iptables DNAT configured for $DEST_IP via default eth0 (${#ZT_INTERFACES[@]} ZeroTier interfaces)"
                        fi
                    fi
                fi

                echo "✓ Port forwarding configured"
            fi
        done
    fi
fi

# Сохраняем конфигурацию для отладки
mkdir -p /tmp/zt-sidecar
cat > /tmp/zt-sidecar/config.json << EOF
{
  "mode": "$GATEWAY_MODE",
  "zerotier_ip": "$ZT_IP",
  "zerotier_interface": "$ZT_IF", 
  "network": "$ZT_NETWORK",
  "port_forwarding": "$PORT_FORWARD",
  "allowed_sources": "$ALLOWED_SOURCES",
  "custom_routes": "$FORCE_ZEROTIER_ROUTES",
  "timestamp": "$(date -Iseconds)"
}
EOF

echo "=== ZeroTier Sidecar Ready ==="
echo "Mode: $GATEWAY_MODE"
echo "ZeroTier IP: $ZT_IP"
echo "Interface: $ZT_IF"
echo "Port forwarding: $PORT_FORWARD"
echo "Allowed sources: $ALLOWED_SOURCES"
if [ -n "$FORCE_ZEROTIER_ROUTES" ]; then
    echo "Custom routes: $FORCE_ZEROTIER_ROUTES"
fi
echo "Config: /tmp/zt-sidecar/config.json"
echo "=============================="

echo ""
echo "=== Port Status Analysis ==="
if [ "$GATEWAY_MODE" = "true" ]; then
    echo "Gateway mode - analyzing port configurations:"
    IFS=',' read -ra FORWARDS <<< "$PORT_FORWARD"
    for forward in "${FORWARDS[@]}"; do
        IFS=':' read -ra PARTS <<< "$forward"
        EXT_PORT=${PARTS[0]}
        DEST_IP=${PARTS[1]}
        DEST_PORT=${PARTS[2]}
        
        if [ -n "$EXT_PORT" ] && [ -n "$DEST_IP" ] && [ -n "$DEST_PORT" ]; then
            if is_zerotier_address "$DEST_IP" >/dev/null 2>&1; then
                echo "✅ Port $EXT_PORT -> $DEST_IP:$DEST_PORT (ZeroTier - external access available)"
            else
                echo "❌ Port $EXT_PORT -> $DEST_IP:$DEST_PORT (Docker - not configured in gateway mode)"
            fi
        fi
    done
    echo "💡 Note: Use GATEWAY_MODE=hybrid for mixed Docker/ZeroTier forwarding"
elif [ "$GATEWAY_MODE" = "hybrid" ]; then
    echo "Hybrid mode - all ports configured for both external and ZeroTier access:"
    IFS=',' read -ra FORWARDS <<< "$PORT_FORWARD"
    for forward in "${FORWARDS[@]}"; do
        IFS=':' read -ra PARTS <<< "$forward"
        EXT_PORT=${PARTS[0]}
        DEST_IP=${PARTS[1]}
        DEST_PORT=${PARTS[2]}
        
        if [ -n "$EXT_PORT" ] && [ -n "$DEST_IP" ] && [ -n "$DEST_PORT" ]; then
            if is_zerotier_address "$DEST_IP" >/dev/null 2>&1; then
                echo "✅ Port $EXT_PORT -> $DEST_IP:$DEST_PORT (ZeroTier - socat proxy)"
            else
                echo "✅ Port $EXT_PORT -> $DEST_IP:$DEST_PORT (Docker - iptables DNAT)"
            fi
        fi
    done
else
    echo "Backend mode - all ports configured for ZeroTier access only:"
    IFS=',' read -ra FORWARDS <<< "$PORT_FORWARD"
    for forward in "${FORWARDS[@]}"; do
        IFS=':' read -ra PARTS <<< "$forward"
        EXT_PORT=${PARTS[0]}
        DEST_IP=${PARTS[1]}
        DEST_PORT=${PARTS[2]}
        
        if [ -n "$EXT_PORT" ] && [ -n "$DEST_IP" ] && [ -n "$DEST_PORT" ]; then
            if is_zerotier_address "$DEST_IP" >/dev/null 2>&1; then
                echo "❌ Port $EXT_PORT -> $DEST_IP:$DEST_PORT (ZeroTier - not configured in backend mode)"
            else
                echo "✅ Port $EXT_PORT -> $DEST_IP:$DEST_PORT (iptables DNAT)"
            fi
        fi
    done
    echo "💡 Note: Use GATEWAY_MODE=hybrid for ZeroTier destinations"
fi
echo "============================"

# Держим контейнер запущенным
tail -f /dev/null
