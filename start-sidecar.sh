#!/bin/bash
set -e

# Переменные окружения
ZT_NETWORK=${ZT_NETWORK:-""}
PORT_FORWARD=${PORT_FORWARD:-""}

echo "Starting ZeroTier sidecar..."
echo "ZeroTier network: $ZT_NETWORK"
echo "Port forwarding: $PORT_FORWARD"

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
    
    # Показываем результат
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
while true; do
    ZT_IP=$(ip -o -4 addr show dev "$ZT_IF" | awk '{print $4}' | cut -d/ -f1)
    if [ -n "$ZT_IP" ]; then
        echo "ZeroTier IP: $ZT_IP"
        break
    fi
    sleep 1
done

# Включаем IP форвардинг
echo "Enabling IP forwarding..."
sysctl -w net.ipv4.ip_forward=1

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
            
            # DNAT: перенаправляем входящий трафик с ZeroTier на Docker сеть
            iptables -t nat -A PREROUTING -i "$ZT_IF" -p tcp --dport $EXT_PORT -j DNAT --to-destination $DEST_IP:$DEST_PORT
            
            # MASQUERADE: маскируем источник при отправке в Docker сеть (ИСПРАВЛЕНО)
            iptables -t nat -A POSTROUTING -o eth0 -p tcp -d $DEST_IP --dport $DEST_PORT -j MASQUERADE
            
            # FORWARD: разрешаем прохождение трафика
            iptables -A FORWARD -i "$ZT_IF" -o eth0 -p tcp -d $DEST_IP --dport $DEST_PORT -j ACCEPT
            iptables -A FORWARD -i eth0 -o "$ZT_IF" -p tcp -s $DEST_IP --sport $DEST_PORT -j ACCEPT
            
            echo "✓ Port forwarding configured"
        fi
    done
fi

echo "=== ZeroTier Sidecar Ready ==="
echo "ZeroTier IP: $ZT_IP"
echo "Interface: $ZT_IF"
echo "Port forwarding: $PORT_FORWARD"
echo "=============================="

# Держим контейнер запущенным
tail -f /dev/null
