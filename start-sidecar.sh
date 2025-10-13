#!/bin/bash
set -e

# Переменные окружения
ZT_NETWORK=${ZT_NETWORK:-""}
PORT_FORWARD=${PORT_FORWARD:-""}

# Improved name resolver: uses getent (NSS: /etc/hosts + Docker DNS) then ping as fallback
resolve_name_to_ip() {
    local name="$1"
    local ip=""

    # If already IPv4, return as-is
    if [[ "$name" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$name"
        return 0
    fi

    # Try getent first (uses Docker embedded DNS)
    if command -v getent >/dev/null 2>&1; then
        ip=$(getent hosts "$name" | awk '{print $1; exit}' || true)
        if [ -n "$ip" ]; then
            echo "$ip"
            return 0
        fi
    fi

    # Fallback to ping
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
    echo "Docker DNS detected:"
    cat /etc/resolv.conf | grep nameserver

    # Add Google DNS as fallback if not present (for ZeroTier external lookups)
    if ! grep -q '8.8.8.8' /etc/resolv.conf 2>/dev/null; then
        echo 'nameserver 8.8.8.8' >> /etc/resolv.conf
        echo "✓ Added 8.8.8.8 as fallback DNS"
    else
        echo "✓ Fallback DNS 8.8.8.8 already present"
    fi

    echo "Final DNS config:"
    cat /etc/resolv.conf | grep nameserver
else
    echo "⚠️  Warning: /etc/resolv.conf is empty or missing"
fi

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

# Pre-resolve container names BEFORE starting ZeroTier
# Docker embedded DNS (127.0.0.11) may stop responding after network changes,
# so we resolve all container names early and cache the IPs
if [ -n "$PORT_FORWARD" ]; then
    echo "Pre-resolving container names..."
    NEW_PORT_FORWARD=""
    IFS=',' read -ra FORWARDS <<< "$PORT_FORWARD"
    for forward in "${FORWARDS[@]}"; do
        IFS=':' read -ra PARTS <<< "$forward"
        EXT_PORT=${PARTS[0]}
        DEST=${PARTS[1]}
        DEST_PORT=${PARTS[2]}

        if [ -n "$EXT_PORT" ] && [ -n "$DEST" ] && [ -n "$DEST_PORT" ]; then
            # Resolve name to IP
            if DEST_IP=$(resolve_name_to_ip "$DEST"); then
                if [ "$DEST" != "$DEST_IP" ]; then
                    echo "  $DEST -> $DEST_IP"
                fi
                NEW_PORT_FORWARD+="${EXT_PORT}:${DEST_IP}:${DEST_PORT},"
            else
                echo "  ⚠️  Cannot resolve: $DEST (skipping)"
            fi
        fi
    done
    PORT_FORWARD=${NEW_PORT_FORWARD%,}
    echo "Resolved PORT_FORWARD: $PORT_FORWARD"
fi

# Включаем IP форвардинг
echo "Enabling IP forwarding..."
sysctl -w net.ipv4.ip_forward=1

# Настройка правил для проброса портов (now using resolved IPs)
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

            # MASQUERADE: маскируем источник при отправке в Docker сеть
            iptables -t nat -A POSTROUTING -o eth0 -p tcp -d $DEST_IP --dport $DEST_PORT -j MASQUERADE

            # FORWARD: разрешаем прохождение трафика
            iptables -A FORWARD -i "$ZT_IF" -o eth0 -p tcp -d $DEST_IP --dport $DEST_PORT -j ACCEPT
            iptables -A FORWARD -i eth0 -o "$ZT_IF" -p tcp -s $DEST_IP --sport $DEST_PORT -j ACCEPT

            echo "✓ Port forwarding configured"
        fi
    done
fi

echo ""
echo "=== DNS Diagnostics ==="
echo "DNS configuration:"
cat /etc/resolv.conf | grep nameserver || echo "⚠️  No nameservers found!"

echo ""
echo "Testing DNS resolution:"

# Test Docker embedded DNS using getent (more reliable than nslookup)
if grep -q '127.0.0.11' /etc/resolv.conf 2>/dev/null; then
    echo -n "Docker embedded DNS (127.0.0.11): "
    if getent hosts google.com >/dev/null 2>&1; then
        echo "✓ Working (getent)"
    else
        echo "✗ Not responding"
    fi
fi

# Test external DNS using ping (more reliable for connectivity check)
echo -n "External connectivity: "
if ping -c 1 -W 2 8.8.8.8 >/dev/null 2>&1; then
    echo "✓ Working"
else
    echo "✗ Failed"
fi

# Test actual DNS resolution
echo -n "DNS resolution test: "
if getent hosts google.com >/dev/null 2>&1; then
    echo "✓ Working"
else
    echo "✗ Failed"
fi
echo "======================="
echo ""

echo "=== ZeroTier Sidecar Ready ==="
echo "ZeroTier IP: $ZT_IP"
echo "Interface: $ZT_IF"
echo "Port forwarding: $PORT_FORWARD"
echo "=============================="

# Держим контейнер запущенным
tail -f /dev/null
