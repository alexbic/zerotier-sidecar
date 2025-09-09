#!/bin/bash
set -e

# Переменные окружения (упрощенные)
ZT_NETWORK=${ZT_NETWORK:-""}
PORT_FORWARD=${PORT_FORWARD:-""}
GATEWAY_MODE=${GATEWAY_MODE:-"false"}
ALLOWED_SOURCES=${ALLOWED_SOURCES:-"any"}

# Исправляем DNS для установки пакетов
echo "nameserver 8.8.8.8" > /etc/resolv.conf

echo "Starting ZeroTier sidecar..."
echo "Mode: $GATEWAY_MODE"
echo "ZeroTier network: $ZT_NETWORK"
echo "Port forwarding: $PORT_FORWARD"

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
    
    # Защита от сканирования портов - ВСЕГДА
    iptables -A INPUT -p tcp --tcp-flags ALL NONE -j DROP
    iptables -A INPUT -p tcp --tcp-flags ALL ALL -j DROP
    iptables -A INPUT -p tcp --tcp-flags SYN,FIN SYN,FIN -j DROP
    iptables -A INPUT -p tcp --tcp-flags SYN,RST SYN,RST -j DROP
    
    echo "✓ Basic firewall rules applied"
}

# Функция для получения интерфейса по которому идет трафик к IP
get_interface_for_ip() {
    local dest_ip="$1"
    
    # Получаем интерфейс через который пойдет трафик к этому IP
    local route_info
    route_info=$(ip route get "$dest_ip" 2>/dev/null)
    
    if [ $? -eq 0 ]; then
        # Извлекаем интерфейс из вывода ip route get
        local interface
        interface=$(echo "$route_info" | grep -o 'dev [^ ]*' | awk '{print $2}')
        echo "$interface"
    else
        # Если маршрут не найден, возвращаем пустую строку
        echo ""
    fi
}

# Функция для автоматического определения типа сети по интерфейсу
is_zerotier_address() {
    local dest_ip="$1"
    local interface
    
    interface=$(get_interface_for_ip "$dest_ip")
    
    echo "Checking route for $dest_ip -> interface: $interface"
    
    # Если интерфейс начинается с "zt" - это ZeroTier
    if [[ "$interface" =~ ^zt ]]; then
        echo "Detected ZeroTier address: $dest_ip (interface: $interface)"
        return 0  # true - ZeroTier адрес
    else
        echo "Detected local/Docker address: $dest_ip (interface: $interface)"
        return 1  # false - Docker или другая локальная сеть
    fi
}

# Проверяем интернет подключение (ОРИГИНАЛЬНАЯ ЛОГИКА)
echo "Testing internet connectivity..."
if ping -c 3 8.8.8.8 >/dev/null 2>&1; then
    echo "✓ Internet connectivity OK"
else
    echo "✗ No internet connectivity - checking network..."
    ip route
fi

# Запускаем ZeroTier (ОРИГИНАЛЬНАЯ ЛОГИКА)
echo "Starting ZeroTier daemon..."
zerotier-one &

# Ждём появления zerotier-cli (ОРИГИНАЛЬНАЯ ЛОГИКА)
echo "Waiting for ZeroTier CLI..."
until command -v zerotier-cli >/dev/null 2>&1; do
    sleep 1
done

# Ждём готовности демона (ОРИГИНАЛЬНАЯ ЛОГИКА)
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

# Присоединяемся к сети (ОРИГИНАЛЬНАЯ ЛОГИКА)
if [ -n "$ZT_NETWORK" ]; then
    echo "Joining ZeroTier network: $ZT_NETWORK"
    zerotier-cli join $ZT_NETWORK
    
    # Показываем результат
    sleep 2
    echo "Network status:"
    zerotier-cli listnetworks
fi

# Ждём появления интерфейса (ОРИГИНАЛЬНАЯ ЛОГИКА)
echo "Waiting for ZeroTier interface..."
while true; do
    ZT_IF=$(ip -o link | awk -F': ' '/zt/ {print $2; exit}')
    if [ -n "$ZT_IF" ]; then
        echo "ZeroTier interface: $ZT_IF"
        break
    fi
    sleep 1
done

# Ждём присвоения IP (УЛУЧШЕННАЯ ВЕРСИЯ с таймаутом)
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

# Включаем IP форвардинг (ОРИГИНАЛЬНАЯ ЛОГИКА)
echo "Enabling IP forwarding..."
sysctl -w net.ipv4.ip_forward=1

# Настраиваем firewall
setup_firewall

# Настройка правил для проброса портов (ИСПРАВЛЕННАЯ ЛОГИКА)
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
                    # Backend: только на ZeroTier интерфейсе
                    echo "Backend mode: opening port $EXT_PORT on ZeroTier interface only"
                    iptables -A INPUT -i "$ZT_IF" -p tcp --dport $EXT_PORT -j ACCEPT
                    ;;
                "true")
                    # Gateway: только снаружи
                    echo "Gateway mode: opening port $EXT_PORT for external access"
                    if [ "$ALLOWED_SOURCES" != "any" ]; then
                        IFS=',' read -ra SOURCES <<< "$ALLOWED_SOURCES"
                        for source in "${SOURCES[@]}"; do
                            iptables -A INPUT -s "$source" -p tcp --dport $EXT_PORT -j ACCEPT
                        done
                    else
                        iptables -A INPUT -p tcp --dport $EXT_PORT -j ACCEPT
                    fi
                    # Разрешаем трафик от Docker сети для межконтейнерного взаимодействия
                    iptables -I INPUT -s 172.16.0.0/12 -p tcp --dport $EXT_PORT -j ACCEPT
                    ;;
                "hybrid")
                    # Гибрид: и снаружи, и на ZeroTier
                    echo "Hybrid mode: opening port $EXT_PORT on all interfaces"
                    if [ "$ALLOWED_SOURCES" != "any" ]; then
                        IFS=',' read -ra SOURCES <<< "$ALLOWED_SOURCES"
                        for source in "${SOURCES[@]}"; do
                            iptables -A INPUT -s "$source" -p tcp --dport $EXT_PORT -j ACCEPT
                        done
                    else
                        iptables -A INPUT -p tcp --dport $EXT_PORT -j ACCEPT
                    fi
                    # Также разрешаем на ZeroTier интерфейсе
                    iptables -A INPUT -i "$ZT_IF" -p tcp --dport $EXT_PORT -j ACCEPT
                    # Разрешаем трафик от Docker сети
                    iptables -I INPUT -s 172.16.0.0/12 -p tcp --dport $EXT_PORT -j ACCEPT
                    ;;
                *)
                    echo "Invalid GATEWAY_MODE: $GATEWAY_MODE. Use: false, true, or hybrid"
                    exit 1
                    ;;
            esac
            
            # Выбираем способ перенаправления в зависимости от типа адреса назначения
            if is_zerotier_address "$DEST_IP"; then
                # Для ZeroTier адресов используем socat прокси
                echo "Destination is ZeroTier address, using socat proxy"
                if [ "$GATEWAY_MODE" = "true" ] || [ "$GATEWAY_MODE" = "hybrid" ]; then
                    echo "Starting socat proxy: $EXT_PORT -> $DEST_IP:$DEST_PORT"
                    socat TCP-LISTEN:$EXT_PORT,bind=0.0.0.0,fork,reuseaddr TCP:$DEST_IP:$DEST_PORT &
                    echo "✓ Socat proxy started for port $EXT_PORT"
                fi
            else
                # Для локальных Docker адресов используем iptables DNAT
                echo "Destination is local Docker address, using iptables DNAT"
                if [ "$GATEWAY_MODE" = "false" ] || [ "$GATEWAY_MODE" = "hybrid" ]; then
                    # Backend режим: DNAT в Docker сеть
                    iptables -t nat -A PREROUTING -i "$ZT_IF" -p tcp --dport $EXT_PORT -j DNAT --to-destination $DEST_IP:$DEST_PORT
                    
                    # Определяем правильный интерфейс для назначения
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
                echo "⚠️  Port $EXT_PORT -> $DEST_IP:$DEST_PORT (Docker - external access not available in gateway mode)"
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
            echo "✅ Port $EXT_PORT -> $DEST_IP:$DEST_PORT (iptables DNAT)"
        fi
    done
fi
echo "============================"

# Держим контейнер запущенным (ОРИГИНАЛЬНАЯ ЛОГИКА)
tail -f /dev/nu
