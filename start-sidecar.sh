#!/bin/bash
set -e

# Переменные окружения
ZT_NETWORK=${ZT_NETWORK:-""}
PORT_FORWARD=${PORT_FORWARD:-""}
GATEWAY_MODE=${GATEWAY_MODE:-"false"}
ALLOWED_SOURCES=${ALLOWED_SOURCES:-"any"}
FORCE_ZEROTIER_ROUTES=${FORCE_ZEROTIER_ROUTES:-""}
DEBUG_IPTABLES=${DEBUG_IPTABLES:-"false"}  # Enable comprehensive iptables logging for debugging

# Simple resolver: use getent (NSS: /etc/hosts + Docker DNS + DNS) then ping as fallback.
resolve_name_to_ip() {
    local name="$1"
    local ip=""

    # if already IPv4
    if [[ "$name" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$name"
        return 0
    fi

    # Try getent first (uses NSS which includes Docker DNS)
    if command -v getent >/dev/null 2>&1; then
        ip=$(getent hosts "$name" 2>/dev/null | awk '{print $1; exit}' || true)
        if [ -n "$ip" ] && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return 0
        fi
    fi

    # Try nslookup with Docker DNS directly
    if command -v nslookup >/dev/null 2>&1; then
        ip=$(nslookup "$name" 127.0.0.11 2>/dev/null | grep -A1 "Name:" | grep "Address:" | awk '{print $2}' | head -1 || true)
        if [ -n "$ip" ] && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "$ip"
            return 0
        fi
    fi

    # fallback to ping (least preferred)
    if command -v ping >/dev/null 2>&1; then
        ip=$(ping -c1 -W1 "$name" 2>/dev/null | head -1 | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | head -1 || true)
        if [ -n "$ip" ] && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
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

    # Check if there are any hostnames to resolve (not just IPs)
    local has_hostnames=false
    IFS=',' read -ra _CHECK <<< "$PORT_FORWARD"
    for f in "${_CHECK[@]}"; do
        IFS=':' read -ra P <<< "$f"
        DST=${P[1]}
        if [[ -n "$DST" ]] && ! [[ "$DST" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            has_hostnames=true
            break
        fi
    done

    # Only wait for Docker DNS if we have hostnames to resolve
    if [ "$has_hostnames" = true ]; then
        echo "Waiting for Docker DNS to be ready..."
        local dns_ready=false
        local attempt=0
        while [ $attempt -lt 10 ]; do
            if getent hosts host.docker.internal >/dev/null 2>&1 || \
               getent hosts gateway.docker.internal >/dev/null 2>&1 || \
               nslookup -timeout=1 localhost 127.0.0.11 >/dev/null 2>&1; then
                dns_ready=true
                echo "✓ Docker DNS is ready"
                break
            fi
            sleep 1
            attempt=$((attempt+1))
        done

        if [ "$dns_ready" = false ]; then
            echo "⚠️  Warning: Docker DNS not responding, will try to resolve anyway"
        fi
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

        # Retry resolution multiple times for container names
        local ipaddr=""
        local resolve_attempt=0
        while [ $resolve_attempt -lt 3 ]; do
            if ipaddr=$(resolve_name_to_ip "$DST"); then
                echo "(pre-resolve) $DST -> $ipaddr"
                new_forwards+="$EXT:$ipaddr:$DPT,"
                break
            fi
            resolve_attempt=$((resolve_attempt+1))
            if [ $resolve_attempt -lt 3 ]; then
                echo "Retrying resolve for $DST (attempt $((resolve_attempt+1))/3)..."
                sleep 1
            fi
        done

        # If still not resolved, keep the name (will be resolved later)
        if [ -z "$ipaddr" ]; then
            echo "⚠️  Could not pre-resolve $DST, will retry during setup"
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

    # Разрешаем новые исходящие соединения через FORWARD (от Docker хостов к ZeroTier)
    iptables -A ZEROTIER_FORWARD -m conntrack --ctstate NEW -j ACCEPT

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

# Функция добавления правил логирования подключений через NFLOG
add_connection_logging() {
    local port="$1"
    local dest_ip="$2"
    local dest_port="$3"

    # Используем NFLOG вместо LOG для отправки в userspace (ulogd2)
    # NFLOG group 1 соответствует настройке в ulogd.conf
    # Логируем только NEW подключения (не весь трафик)
    # Ограничиваем частоту: 3 сообщения в минуту для каждого порта

    # Добавляем в ZEROTIER_INPUT (для входящих подключений напрямую к контейнеру)
    iptables -I ZEROTIER_INPUT 1 -p tcp --dport "$port" -m conntrack --ctstate NEW \
        -m limit --limit 3/min --limit-burst 5 \
        -j NFLOG --nflog-group 1 --nflog-prefix "PORT-${port}" 2>/dev/null || true

    # Добавляем в ZEROTIER_FORWARD (для пересылаемых подключений с DNAT)
    # Это нужно для портов, которые перенаправляются на Docker контейнеры
    iptables -I ZEROTIER_FORWARD 1 -p tcp --dport "$port" -m conntrack --ctstate NEW \
        -m limit --limit 3/min --limit-burst 5 \
        -j NFLOG --nflog-group 1 --nflog-prefix "PORT-${port}" 2>/dev/null || true
}

# Функция для полного отладочного логирования ВСЕХ iptables цепочек
# Используется для диагностики сетевых проблем
# Включается через переменную DEBUG_IPTABLES=true
add_debug_logging() {
    echo ""
    echo "🔍 DEBUG MODE: Adding comprehensive iptables logging..."
    echo "⚠️  WARNING: This will generate A LOT of log entries!"
    echo ""

    # FILTER table - основные цепочки пакетной фильтрации
    echo "Adding logging to FILTER table..."

    # INPUT chain - входящие пакеты для локальных процессов
    iptables -I INPUT 1 -m limit --limit 10/min --limit-burst 20 \
        -j LOG --log-prefix "[DBG-INPUT] " --log-level 4 2>/dev/null || true

    # OUTPUT chain - исходящие пакеты от локальных процессов
    iptables -I OUTPUT 1 -m limit --limit 10/min --limit-burst 20 \
        -j LOG --log-prefix "[DBG-OUTPUT] " --log-level 4 2>/dev/null || true

    # FORWARD chain - транзитные пакеты (роутинг/DNAT)
    iptables -I FORWARD 1 -m limit --limit 10/min --limit-burst 20 \
        -j LOG --log-prefix "[DBG-FORWARD] " --log-level 4 2>/dev/null || true

    # Наши пользовательские цепочки
    iptables -I ZEROTIER_INPUT 1 -m limit --limit 10/min --limit-burst 20 \
        -j LOG --log-prefix "[DBG-ZT-IN] " --log-level 4 2>/dev/null || true

    iptables -I ZEROTIER_FORWARD 1 -m limit --limit 10/min --limit-burst 20 \
        -j LOG --log-prefix "[DBG-ZT-FWD] " --log-level 4 2>/dev/null || true

    # NAT table - трансляция адресов
    echo "Adding logging to NAT table..."

    # PREROUTING - изменение destination перед роутингом (DNAT)
    iptables -t nat -I PREROUTING 1 -m limit --limit 10/min --limit-burst 20 \
        -j LOG --log-prefix "[DBG-NAT-PRE] " --log-level 4 2>/dev/null || true

    # POSTROUTING - изменение source после роутинга (SNAT/MASQUERADE)
    iptables -t nat -I POSTROUTING 1 -m limit --limit 10/min --limit-burst 20 \
        -j LOG --log-prefix "[DBG-NAT-POST] " --log-level 4 2>/dev/null || true

    # OUTPUT - изменение destination для локально-генерируемых пакетов
    iptables -t nat -I OUTPUT 1 -m limit --limit 10/min --limit-burst 20 \
        -j LOG --log-prefix "[DBG-NAT-OUT] " --log-level 4 2>/dev/null || true

    # MANGLE table - модификация пакетов (TTL, TOS и т.д.)
    echo "Adding logging to MANGLE table..."

    iptables -t mangle -I PREROUTING 1 -m limit --limit 10/min --limit-burst 20 \
        -j LOG --log-prefix "[DBG-MGL-PRE] " --log-level 4 2>/dev/null || true

    iptables -t mangle -I POSTROUTING 1 -m limit --limit 10/min --limit-burst 20 \
        -j LOG --log-prefix "[DBG-MGL-POST] " --log-level 4 2>/dev/null || true

    echo "✅ Debug logging enabled for all iptables chains"
    echo "📝 Check logs with: docker exec <container> dmesg | grep 'DBG-'"
    echo ""
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

    # Добавляем правила форвардинга между ZeroTier интерфейсами
    # НЕ добавляем общее ACCEPT для ZeroTier интерфейсов здесь!
    # Оно будет добавлено в самом конце, ПОСЛЕ NFLOG правил логирования
    for zt_iface in "${ZT_INTERFACES[@]}"; do
        echo "Adding forwarding rules for interface: $zt_iface"

        # Разрешаем форвардинг между всеми ZeroTier интерфейсами
        for zt_iface2 in "${ZT_INTERFACES[@]}"; do
            iptables -I ZEROTIER_FORWARD -i "$zt_iface" -o "$zt_iface2" -j ACCEPT
        done
    done

    echo "✓ ZeroTier forwarding rules added for ${#ZT_INTERFACES[@]} interface(s)"
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
# Создаём ассоциативный массив для хранения маппинга IP -> оригинальное имя
declare -A IP_TO_NAME_MAP

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
        # Retry resolution with backoff
        retry_attempt=0
        while [ $retry_attempt -lt 3 ]; do
            echo "Attempting to resolve '$RAW_DEST' (attempt $((retry_attempt+1))/3)..."
            if RESOLVED_IP=$(resolve_name_to_ip "$RAW_DEST"); then
                echo "✓ Resolved $RAW_DEST -> $RESOLVED_IP"
                # Сохраняем маппинг IP -> имя для логирования
                IP_TO_NAME_MAP["$RESOLVED_IP"]="$RAW_DEST"
                RESOLVED_FORWARDS+="${EXT_PORT}:${RESOLVED_IP}:${DEST_PORT},"
                break
            fi
            retry_attempt=$((retry_attempt+1))
            if [ $retry_attempt -lt 3 ]; then
                echo "⚠️  Failed to resolve '$RAW_DEST', retrying in 2 seconds..."
                sleep 2
            fi
        done

        if [ -z "$RESOLVED_IP" ]; then
            echo "✗ ERROR: Cannot resolve destination: '$RAW_DEST' after 3 attempts"
            echo "✗ Skipping rule $EXT_PORT:$RAW_DEST:$DEST_PORT"
            echo "✗ Please check:"
            echo "  - Container '$RAW_DEST' exists and is running"
            echo "  - Container is in the same Docker network"
            echo "  - Docker DNS is working (127.0.0.11)"
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

# КРИТИЧЕСКИ ВАЖНО: Добавляем LOG правила В САМОМ КОНЦЕ, после всех ACCEPT правил!
# Используем -I (insert at position 1), чтобы LOG правила оказались В НАЧАЛЕ цепочки
# Добавляем в ОБРАТНОМ порядке, чтобы первый порт оказался первым в цепочке
echo ""
echo "Adding connection logging rules..."
if [ -n "$RESOLVED_FORWARDS" ]; then
    # Создаём массив портов
    IFS=',' read -ra FORWARDS <<< "$RESOLVED_FORWARDS"
    PORTS_ARRAY=()

    for forward in "${FORWARDS[@]}"; do
        IFS=':' read -ra PARTS <<< "$forward"
        EXT_PORT=${PARTS[0]}
        DEST_IP=${PARTS[1]}
        DEST_PORT=${PARTS[2]}
        if [ -n "$EXT_PORT" ] && [ -n "$DEST_IP" ] && [ -n "$DEST_PORT" ]; then
            PORTS_ARRAY+=("$EXT_PORT:$DEST_IP:$DEST_PORT")
        fi
    done

    # Добавляем LOG правила в ОБРАТНОМ порядке (от последнего к первому)
    # чтобы при вставке с -I они оказались в правильном порядке
    for ((i=${#PORTS_ARRAY[@]}-1; i>=0; i--)); do
        IFS=':' read -ra PARTS <<< "${PORTS_ARRAY[$i]}"
        EXT_PORT=${PARTS[0]}
        DEST_IP=${PARTS[1]}
        DEST_PORT=${PARTS[2]}
        add_connection_logging "$EXT_PORT" "$DEST_IP" "$DEST_PORT"
        echo "✓ Added logging for port $EXT_PORT"
    done
    echo "✓ Connection logging rules added ($(echo ${#PORTS_ARRAY[@]}) ports)"
fi

# Добавляем полное отладочное логирование если DEBUG_IPTABLES=true
if [ "$DEBUG_IPTABLES" = "true" ]; then
    add_debug_logging
fi

# Теперь добавляем общее ACCEPT правило для ZeroTier интерфейсов
# ВАЖНО: Это должно быть В САМОМ КОНЦЕ, после всех NFLOG правил!
# Используем -A (append), чтобы правило оказалось в конце цепочки
if [ "$GATEWAY_MODE" = "hybrid" ] || [ "$GATEWAY_MODE" = "true" ]; then
    echo ""
    echo "Adding final ZeroTier ACCEPT rules..."
    for zt_iface in "${ZT_INTERFACES[@]}"; do
        iptables -A ZEROTIER_INPUT -i "$zt_iface" -j ACCEPT
        echo "✓ Added ACCEPT rule for interface: $zt_iface"
    done
    echo "✓ ZeroTier interface ACCEPT rules added (after logging rules)"
fi

echo "============================"

# === SERVICE MONITORING AND AUTO-RECOVERY ===
echo ""
echo "=== Starting Service Monitor ==="

# Настройка логирования
LOG_DIR="/var/log/zerotier-sidecar"
LOG_FILE="$LOG_DIR/monitor.log"
CONNECTION_LOG="$LOG_DIR/connections.log"
MAX_LOG_SIZE=10485760  # 10MB
MAX_LOG_FILES=5

# Создаём директорию для логов
mkdir -p "$LOG_DIR"

# Функция логирования с timestamp
log_message() {
    local level="$1"
    shift
    local message="$*"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$timestamp] [$level] $message" | tee -a "$LOG_FILE"
}

# Функция ротации логов
rotate_logs() {
    local logfile="$1"

    if [ -f "$logfile" ] && [ $(stat -f%z "$logfile" 2>/dev/null || stat -c%s "$logfile" 2>/dev/null) -gt $MAX_LOG_SIZE ]; then
        for i in $(seq $((MAX_LOG_FILES-1)) -1 1); do
            if [ -f "${logfile}.$i" ]; then
                mv "${logfile}.$i" "${logfile}.$((i+1))"
            fi
        done
        mv "$logfile" "${logfile}.1"
        touch "$logfile"
        log_message "INFO" "Log rotated: $(basename $logfile)"
    fi
}

# Хранилище состояния сервисов
declare -A SERVICE_STATE
declare -A SERVICE_LAST_SEEN

# Функция для получения отображаемого имени (имя контейнера или IP)
get_display_name() {
    local ip="$1"
    # Если есть маппинг, возвращаем имя, иначе IP
    if [ -n "${IP_TO_NAME_MAP[$ip]}" ]; then
        echo "${IP_TO_NAME_MAP[$ip]} ($ip)"
    else
        echo "$ip"
    fi
}

# Функция проверки и восстановления правил для одного форварда
check_and_restore_forward() {
    local ext_port="$1"
    local dest_ip="$2"
    local dest_port="$3"
    local is_zt_addr="$4"
    local service_key="${ext_port}:${dest_ip}:${dest_port}"
    local display_name=$(get_display_name "$dest_ip")

    # Проверяем доступность целевого сервиса
    if ! nc -z -w 2 "$dest_ip" "$dest_port" >/dev/null 2>&1; then
        # Сервис недоступен
        if [ "${SERVICE_STATE[$service_key]}" != "down" ]; then
            log_message "WARN" "Service DOWN: $display_name:$dest_port (port $ext_port)"
            SERVICE_STATE[$service_key]="down"
        fi
        return 1
    fi

    # Сервис доступен - проверяем было ли восстановление
    if [ "${SERVICE_STATE[$service_key]}" = "down" ]; then
        log_message "INFO" "Service RESTORED: $display_name:$dest_port (port $ext_port) - service is back online"
        SERVICE_STATE[$service_key]="up"
    elif [ -z "${SERVICE_STATE[$service_key]}" ]; then
        # Первая проверка
        SERVICE_STATE[$service_key]="up"
    fi

    SERVICE_LAST_SEEN[$service_key]=$(date +%s)

    # Проверяем наличие правил iptables
    local rules_exist=false

    if [ "$is_zt_addr" = "false" ]; then
        # Для Docker сервисов проверяем DNAT правила
        if iptables -t nat -L PREROUTING -n | grep -q "dpt:$ext_port.*to:$dest_ip:$dest_port"; then
            rules_exist=true
        fi
    else
        # Для ZeroTier сервисов проверяем socat процесс
        if pgrep -f "socat.*TCP-LISTEN:$ext_port.*TCP:$dest_ip:$dest_port" >/dev/null 2>&1; then
            rules_exist=true
        fi
    fi

    if [ "$rules_exist" = false ]; then
        log_message "WARN" "Rules missing for port $ext_port -> $display_name:$dest_port - restoring..."
        restore_forward_rules "$ext_port" "$dest_ip" "$dest_port" "$is_zt_addr"
        log_message "INFO" "Rules RESTORED: port $ext_port -> $display_name:$dest_port"
        return 2
    fi

    return 0
}

# Функция восстановления правил
restore_forward_rules() {
    local ext_port="$1"
    local dest_ip="$2"
    local dest_port="$3"
    local is_zt_addr="$4"

    echo "  → Opening port $ext_port in firewall..."

    # Восстанавливаем firewall правила в зависимости от режима
    case $GATEWAY_MODE in
        "false")
            for zt_iface in "${ZT_INTERFACES[@]}"; do
                iptables -I ZEROTIER_INPUT -i "$zt_iface" -p tcp --dport $ext_port -j ACCEPT 2>/dev/null || true
            done
            ;;
        "true")
            if [ "$ALLOWED_SOURCES" != "any" ]; then
                IFS=',' read -ra SOURCES <<< "$ALLOWED_SOURCES"
                for source in "${SOURCES[@]}"; do
                    iptables -I ZEROTIER_INPUT -s "$source" -p tcp --dport $ext_port -j ACCEPT 2>/dev/null || true
                done
            else
                iptables -I ZEROTIER_INPUT -p tcp --dport $ext_port -j ACCEPT 2>/dev/null || true
            fi
            add_docker_network_rules "$ext_port"
            ;;
        "hybrid")
            if [ "$ALLOWED_SOURCES" != "any" ]; then
                IFS=',' read -ra SOURCES <<< "$ALLOWED_SOURCES"
                for source in "${SOURCES[@]}"; do
                    iptables -I ZEROTIER_INPUT -s "$source" -p tcp --dport $ext_port -j ACCEPT 2>/dev/null || true
                done
            else
                iptables -I ZEROTIER_INPUT -p tcp --dport $ext_port -j ACCEPT 2>/dev/null || true
            fi
            for zt_iface in "${ZT_INTERFACES[@]}"; do
                iptables -I ZEROTIER_INPUT -i "$zt_iface" -p tcp --dport $ext_port -j ACCEPT 2>/dev/null || true
            done
            add_docker_network_rules "$ext_port"
            ;;
    esac

    # Восстанавливаем перенаправление
    if [ "$is_zt_addr" = "true" ]; then
        echo "  → Starting socat proxy: $ext_port -> $dest_ip:$dest_port"
        if [ "$GATEWAY_MODE" = "true" ] || [ "$GATEWAY_MODE" = "hybrid" ]; then
            # Убиваем старый процесс если есть
            pkill -f "socat.*TCP-LISTEN:$ext_port.*TCP:$dest_ip:$dest_port" 2>/dev/null || true
            sleep 1
            # Запускаем новый
            socat TCP-LISTEN:$ext_port,bind=0.0.0.0,fork,reuseaddr TCP:$dest_ip:$dest_port &
            echo "  ✓ Socat proxy restored"
        fi
    else
        echo "  → Restoring iptables DNAT: $ext_port -> $dest_ip:$dest_port"
        if [ "$GATEWAY_MODE" = "false" ] || [ "$GATEWAY_MODE" = "hybrid" ]; then
            DEST_INTERFACE=$(get_interface_for_ip "$dest_ip")

            # Создаём DNAT правила для всех ZeroTier интерфейсов
            for zt_iface in "${ZT_INTERFACES[@]}"; do
                # Проверяем, нет ли уже правила
                if ! iptables -t nat -L PREROUTING -n | grep -q "dpt:$ext_port.*to:$dest_ip:$dest_port"; then
                    iptables -t nat -A PREROUTING -i "$zt_iface" -p tcp --dport $ext_port -j DNAT --to-destination $dest_ip:$dest_port 2>/dev/null || true
                fi

                if [ -n "$DEST_INTERFACE" ]; then
                    iptables -A FORWARD -i "$zt_iface" -o "$DEST_INTERFACE" -p tcp -d $dest_ip --dport $dest_port -j ACCEPT 2>/dev/null || true
                    iptables -A FORWARD -i "$DEST_INTERFACE" -o "$zt_iface" -p tcp -s $dest_ip --sport $dest_port -j ACCEPT 2>/dev/null || true
                else
                    iptables -A FORWARD -i "$zt_iface" -o eth0 -p tcp -d $dest_ip --dport $dest_port -j ACCEPT 2>/dev/null || true
                    iptables -A FORWARD -i eth0 -o "$zt_iface" -p tcp -s $dest_ip --sport $dest_port -j ACCEPT 2>/dev/null || true
                fi
            done

            # MASQUERADE правило
            if [ -n "$DEST_INTERFACE" ]; then
                if ! iptables -t nat -L POSTROUTING -n | grep -q "MASQUERADE.*$dest_ip.*dpt:$dest_port"; then
                    iptables -t nat -A POSTROUTING -o "$DEST_INTERFACE" -p tcp -d $dest_ip --dport $dest_port -j MASQUERADE 2>/dev/null || true
                fi
            else
                if ! iptables -t nat -L POSTROUTING -n | grep -q "MASQUERADE.*$dest_ip.*dpt:$dest_port"; then
                    iptables -t nat -A POSTROUTING -o eth0 -p tcp -d $dest_ip --dport $dest_port -j MASQUERADE 2>/dev/null || true
                fi
            fi

            echo "  ✓ iptables DNAT rules restored"
        fi
    fi
}

# Фоновый процесс мониторинга
monitor_services() {
    local check_interval=30  # Проверка каждые 30 секунд
    local restore_count=0
    local health_check_counter=0

    log_message "INFO" "Monitor started: checking services every ${check_interval}s"
    log_message "INFO" "Monitoring $(echo "$RESOLVED_FORWARDS" | tr ',' '\n' | wc -l) forward rules"

    while true; do
        sleep "$check_interval"

        # Ротация логов при необходимости
        rotate_logs "$LOG_FILE"
        rotate_logs "$CONNECTION_LOG"

        # Проверяем каждый форвард
        if [ -n "$RESOLVED_FORWARDS" ]; then
            IFS=',' read -ra FORWARDS <<< "$RESOLVED_FORWARDS"
            local issues_found=false

            for forward in "${FORWARDS[@]}"; do
                IFS=':' read -ra PARTS <<< "$forward"
                EXT_PORT=${PARTS[0]}
                DEST_IP=${PARTS[1]}
                DEST_PORT=${PARTS[2]}

                if [ -n "$EXT_PORT" ] && [ -n "$DEST_IP" ] && [ -n "$DEST_PORT" ]; then
                    # Определяем тип адреса
                    local is_zt="false"
                    if is_zerotier_address "$DEST_IP" >/dev/null 2>&1; then
                        is_zt="true"
                    fi

                    # Проверяем и восстанавливаем при необходимости
                    check_and_restore_forward "$EXT_PORT" "$DEST_IP" "$DEST_PORT" "$is_zt"
                    local result=$?

                    if [ $result -eq 1 ]; then
                        issues_found=true
                    elif [ $result -eq 2 ]; then
                        issues_found=true
                        restore_count=$((restore_count + 1))
                    fi
                fi
            done

            # Периодический health check log (каждые 10 проверок = 5 минут)
            health_check_counter=$((health_check_counter + 1))
            if [ "$issues_found" = false ] && [ $((health_check_counter % 10)) -eq 0 ]; then
                log_message "INFO" "Health check: All services healthy (${#FORWARDS[@]} rules checked, $restore_count total restorations)"
            fi
        fi
    done
}

# Запуск ulogd2 для логирования подключений через NFLOG
# ulogd2 получает пакеты из iptables NFLOG и записывает в connections.log
start_ulogd() {
    log_message "INFO" "Starting ulogd2 for connection logging (NFLOG mode)"

    # Создаём директорию для логов если её нет
    mkdir -p "$LOG_DIR"

    # Запускаем ulogd в foreground mode (будет работать в фоне через &)
    # Пакет ulogd2 устанавливает бинарник как /usr/sbin/ulogd (без цифры 2)
    /usr/sbin/ulogd -c /etc/ulogd.conf &
    ULOGD_PID=$!

    # Даём ulogd2 время запуститься
    sleep 2

    # Проверяем что ulogd2 запустился
    if ps -p $ULOGD_PID > /dev/null 2>&1; then
        log_message "INFO" "ulogd2 started successfully (PID: $ULOGD_PID)"
        echo "✓ Connection logger started (PID: $ULOGD_PID)"
        echo "  - Mode: NFLOG + ulogd2"
        echo "  - Log file: $CONNECTION_LOG"
        echo "  - Format: Full connection details (SRC, DST, PORT)"
    else
        log_message "ERROR" "Failed to start ulogd2"
        echo "⚠️  Connection logger failed to start"
    fi
}

# Запускаем ulogd2 для логирования подключений
start_ulogd

# Запускаем мониторинг сервисов в фоне
if [ -n "$RESOLVED_FORWARDS" ]; then
    log_message "INFO" "Starting service monitor..."
    monitor_services &
    MONITOR_PID=$!
    echo "✓ Service monitor started (PID: $MONITOR_PID)"
    echo "  - Check interval: 30 seconds"
    echo "  - Auto-recovery: enabled"
    echo "  - Log file: $LOG_FILE"
    log_message "INFO" "Service monitor started (PID: $MONITOR_PID)"
else
    echo "ℹ️  Service monitor not started (no port forwards configured)"
fi

echo "===================================="
echo ""

# Держим контейнер запущенным
tail -f /dev/null
