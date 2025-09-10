#!/bin/bash
set -e

# Переменные окружения
ZT_NETWORK=${ZT_NETWORK:-""}
PORT_FORWARD=${PORT_FORWARD:-""}
GATEWAY_MODE=${GATEWAY_MODE:-"false"}
ALLOWED_SOURCES=${ALLOWED_SOURCES:-"any"}
FORCE_ZEROTIER_ROUTES=${FORCE_ZEROTIER_ROUTES:-""}

# Исправляем DNS для установки пакетов
echo "nameserver 8.8.8.8" > /etc/resolv.conf

echo "Starting ZeroTier sidecar..."
echo "Mode: $GATEWAY_MODE"
echo "ZeroTier network: $ZT_NETWORK"
echo "Port forwarding: $PORT_FORWARD"
if [ -n "$FORCE_ZEROTIER_ROUTES" ]; then
    echo "Custom routes: $FORCE_ZEROTIER_ROUTES"
fi

# Функция настройки firewall
setup_firewall() {
    echo "Setting up firewall rules..."
    
    # Очищаем существующие правила
    iptables -F 2>/dev/null || true
    iptables -t nat -F 2>/dev/null || true
    iptables -X 2>/dev/null || true
    
    # Блокируем всё по умолчанию
    iptables -P INPUT DROP
    iptables -P FORWARD DROP  
    iptables -P OUTPUT ACCEPT
    
    # Разрешаем loopback
    iptables -A INPUT -i lo -j ACCEPT
    
    # Разрешаем established соединения
    iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -A FORWARD -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    
    # Всегда разрешаем ZeroTier UDP
    iptables -A INPUT -p udp --dport 9993 -j ACCEPT
    
    # Защита от сканирования портов
    iptables -A INPUT -p tcp --tcp-flags ALL NONE -j DROP
    iptables -A INPUT -p tcp --tcp-flags ALL ALL -j DROP
    iptables -A INPUT -p tcp --tcp-flags SYN,FIN SYN,FIN -j DROP
    iptables -A INPUT -p tcp --tcp-flags SYN,RST SYN,RST -j DROP
    
    echo "✓ Basic firewall rules applied"
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
            iptables -I INPUT -s "$network" -p tcp --dport "$port" -j ACCEPT
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

# Присоединяемся к сети
if [ -n "$ZT_NETWORK" ]; then
    echo "Joining ZeroTier network: $ZT_NETWORK"
    zerotier-cli join $ZT_NETWORK
    
    sleep 2
    echo "Network status:"
    zerotier-cli listnetworks
fi

# Ждём появления интерфейса
echo "Waiting for ZeroTier interface..."
while true; do
    ZT_IF=$(ip -o link | awk -F': ' '/zt/ {print $2; exit}')
    if [ -n "$ZT_IF" ]; then
        echo "ZeroTier interface: $ZT_IF"
        break
    fi
    sleep 1
done

# Ждём присвоения IP
echo "Waiting for IP assignment..."
attempt=0
while [ $attempt -lt 60 ]; do
    ZT_IP=$(ip -o -4 addr show dev "$ZT_IF" | awk '{print $4}' | cut -d/ -f1)
    if [ -n "$ZT_IP" ]; then
        echo "ZeroTier IP: $ZT_IP"
        break
    fi
    sleep 2
    attempt=$((attempt+1))
done

if [ -z "$ZT_IP" ]; then
    echo "✗ Failed to get ZeroTier IP"
    exit 1
fi

# Разрешаем трафик на ZeroTier интерфейсе для hybrid/gateway режимов
if [ "$GATEWAY_MODE" = "hybrid" ] || [ "$GATEWAY_MODE" = "true" ]; then
    echo "Adding ZeroTier interface rules for $GATEWAY_MODE mode..."
    iptables -I INPUT -i "$ZT_IF" -j ACCEPT
    iptables -I FORWARD -i "$ZT_IF" -o "$ZT_IF" -j ACCEPT
    echo "✓ ZeroTier internal traffic allowed"
fi

# Включаем IP форвардинг
echo "Enabling IP forwarding..."
sysctl -w net.ipv4.ip_forward=1

# Настраиваем firewall
setup_firewall

# Применяем кастомные маршруты
apply_custom_routes

# Настройка правил для проброса портов
if [ -n "$PORT_FORWARD" ]; then
    echo "Setting up port forwarding..."
    
    IFS=',' read -ra FORWARDS <<< "$PORT_FORWARD"
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
                    echo "Backend mode: opening port $EXT_PORT on ZeroTier interface only"
                    iptables -A INPUT -i "$ZT_IF" -p tcp --dport $EXT_PORT -j ACCEPT
                    ;;
                "true")
                    echo "Gateway mode: opening port $EXT_PORT for external access"
                    if [ "$ALLOWED_SOURCES" != "any" ]; then
                        IFS=',' read -ra SOURCES <<< "$ALLOWED_SOURCES"
                        for source in "${SOURCES[@]}"; do
                            iptables -A INPUT -s "$source" -p tcp --dport $EXT_PORT -j ACCEPT
                        done
                    else
                        iptables -A INPUT -p tcp --dport $EXT_PORT -j ACCEPT
                    fi
                    add_docker_network_rules "$EXT_PORT"
                    ;;
                "hybrid")
                    echo "Hybrid mode: opening port $EXT_PORT on all interfaces"
                    if [ "$ALLOWED_SOURCES" != "any" ]; then
                        IFS=',' read -ra SOURCES <<< "$ALLOWED_SOURCES"
                        for source in "${SOURCES[@]}"; do
                            iptables -A INPUT -s "$source" -p tcp --dport $EXT_PORT -j ACCEPT
                        done
                    else
                        iptables -A INPUT -p tcp --dport $EXT_PORT -j ACCEPT
                    fi
                    iptables -A INPUT -i "$ZT_IF" -p tcp --dport $EXT_PORT -j ACCEPT
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
                    iptables -t nat -A PREROUTING -i "$ZT_IF" -p tcp --dport $EXT_PORT -j DNAT --to-destination $DEST_IP:$DEST_PORT
                    
                    DEST_INTERFACE=$(get_interface_for_ip "$DEST_IP")
                    if [ -n "$DEST_INTERFACE" ]; then
                        iptables -t nat -A POSTROUTING -o "$DEST_INTERFACE" -p tcp -d $DEST_IP --dport $DEST_PORT -j MASQUERADE
                        iptables -A FORWARD -i "$ZT_IF" -o "$DEST_INTERFACE" -p tcp -d $DEST_IP --dport $DEST_PORT -j ACCEPT
                        iptables -A FORWARD -i "$DEST_INTERFACE" -o "$ZT_IF" -p tcp -s $DEST_IP --sport $DEST_PORT -j ACCEPT
                        echo "✓ iptables DNAT configured for $DEST_IP via interface $DEST_INTERFACE"
                    else
                        echo "⚠️  Could not determine interface for $DEST_IP, using eth0"
                        iptables -t nat -A POSTROUTING -o eth0 -p tcp -d $DEST_IP --dport $DEST_PORT -j MASQUERADE
                        iptables -A FORWARD -i "$ZT_IF" -o eth0 -p tcp -d $DEST_IP --dport $DEST_PORT -j ACCEPT
                        iptables -A FORWARD -i eth0 -o "$ZT_IF" -p tcp -s $DEST_IP --sport $DEST_PORT -j ACCEPT
                        echo "✓ iptables DNAT configured for $DEST_IP via default eth0"
                    fi
                fi
            fi
            
            echo "✓ Port forwarding configured"
        fi
    done
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
