# 🌐 ZeroTier Sidecar Gateway v2.2

[![Docker Pulls](https://img.shields.io/docker/pulls/alexbic/zerotier-sidecar)](https://hub.docker.com/r/alexbic/zerotier-sidecar)
[![Docker Image Size](https://img.shields.io/docker/image-size/alexbic/zerotier-sidecar/latest)](https://hub.docker.com/r/alexbic/zerotier-sidecar)
[![License](https://img.shields.io/github/license/alexbic/zerotier-sidecar)](LICENSE)
[![GitHub Stars](https://img.shields.io/github/stars/alexbic/zerotier-sidecar)](https://github.com/alexbic/zerotier-sidecar/stargazers)

🇺🇸 English | [🇷🇺 Русский](README.ru.md)

A powerful Docker container that acts as a ZeroTier network bridge with multiple operation modes:
- **Backend Mode**: ZeroTier networks → Docker containers  
- **Gateway Mode**: Internet → ZeroTier networks (NEW!)
- **Hybrid Mode**: Both directions simultaneously

Perfect for creating secure access chains and accessing services remotely through ZeroTier's encrypted network mesh.

## 🐳 Docker Images

Docker images are available on both **Docker Hub** and **GitHub Container Registry**:

**Docker Hub**: [`alexbic/zerotier-sidecar`](https://hub.docker.com/r/alexbic/zerotier-sidecar)
```bash
# Pull the latest version (v2.x with Gateway support)
docker pull alexbic/zerotier-sidecar:latest

# Or pull legacy v1.x Core (backend-only mode)
docker pull alexbic/zerotier-sidecar:core
docker pull alexbic/zerotier-sidecar:v1.1.1
```

**GitHub Container Registry**: [`ghcr.io/alexbic/zerotier-sidecar`](https://github.com/alexbic/zerotier-sidecar/pkgs/container/zerotier-sidecar)
```bash
docker pull ghcr.io/alexbic/zerotier-sidecar:latest
```

## 🚀 Features

### Core Features
- **🔐 Secure Port Forwarding**: Flexible port mapping with automatic protocol detection
- **🏷️ Container Name Resolution**: Use container names instead of IPs in port forwarding rules
- **📦 Easy Deployment**: Single Docker container with simple configuration
- **🌐 Full ZeroTier Integration**: Seamless bridge between networks
- **🛡️ Automatic Security**: Built-in firewall rules with port scan protection
- **🔍 Smart DNS Management**: Preserves Docker embedded DNS for seamless service discovery

### Operation Modes (NEW in v2.0)
- **Backend Mode**: Traditional ZeroTier → Docker forwarding
- **Gateway Mode**: Internet → ZeroTier tunneling with automatic proxy
- **Hybrid Mode**: Simultaneous bidirectional forwarding

### Advanced Features (NEW in v2.0)
- **🔍 Smart Routing**: Automatic detection of ZeroTier vs Docker networks
- **🎯 Custom Routes**: Support for complex network topologies
- **🔒 Source Filtering**: IP-based access control
- **📊 Real-time Monitoring**: Detailed logging and configuration tracking

### Monitoring & Reliability (Enhanced in v2.2.0!)
- **📺 Real-time Connection Logs**: Live monitoring in `docker logs` with service name resolution
- **🎚️ Flexible Logging Modes**: off/simple/full - choose output level for your needs
- **🔄 Auto-Recovery**: Automatic restoration of missing iptables/socat rules
- **💚 Health Checks**: Continuous service availability monitoring (every 30s)
- **📊 Service Name Mapping**: Displays container names alongside IPs (`rsync-server (172.22.0.3)`)
- **📝 Original Config Display**: Shows user-configured names in port forwarding output
- **🔁 Log Rotation**: Automatic rotation (10MB limit, 5 historical files)
- **⚠️ State Tracking**: Detects and logs service state changes

## 🎯 Use Cases

### Backend Mode (Traditional)
- **🏠 Home Lab Access**: Access your home services securely from anywhere
- **💾 Remote Backup**: Enable rsync, NAS, or backup services over ZeroTier
- **🖥️ Development**: Access development environments remotely

### Gateway Mode (NEW!)
- **🌉 Secure Tunnels**: Create Internet→ZeroTier→Services access chains
- **🔒 Jump Servers**: Secure entry points to private networks  
- **🏢 Corporate Access**: Controlled external access to internal services
- **🌍 Global Distribution**: Access services across geographic regions

### Advanced Scenarios
- **📡 IoT Connectivity**: Connect IoT devices across complex network topologies
- **🔧 System Administration**: Multi-hop SSH and service management
- **🔄 Load Balancing**: Distribute traffic across ZeroTier networks

## 📋 Architecture

### Backend Mode (Traditional)
```
ZeroTier Client → ZeroTier Network → Sidecar (iptables) → Docker Service
                                   (172.26.0.2)        (172.26.0.3:873)
```

### Gateway Mode (NEW!)
```
Internet Client → Gateway Sidecar (socat) → ZeroTier → Backend Sidecar (iptables) → Docker Service
               (203.0.113.100)  (172.26.0.2:8989)         (10.121.15.16:8989)    (172.20.0.2:8080)
```

### Hybrid Mode
```
Internet Client ──┐
                  ├→ Hybrid Sidecar ←─ ZeroTier Client
ZeroTier Client ──┘    (all modes)
                            ↓
                     Docker Services
```

## 📋 Quick Start

### Backend Mode (Traditional)

1. **Create project directory**:
```bash
mkdir zerotier-backend && cd zerotier-backend
```

2. **Create `docker-compose.yml`**:
```yaml
version: "3.8"

services:
  zerotier-sidecar:
    # Available on Docker Hub or GitHub Container Registry
    image: alexbic/zerotier-sidecar:latest
    # Alternative: ghcr.io/alexbic/zerotier-sidecar:latest
    container_name: zerotier-sidecar
    restart: unless-stopped
    privileged: true
    devices:
      - /dev/net/tun:/dev/net/tun
    volumes:
      - ./sidecar-data:/var/lib/zerotier-one      # ZeroTier identity
      - ./sidecar-logs:/var/log/zerotier-sidecar  # Monitoring logs (NEW!)
      - /var/log/kern.log:/var/log/kern.log:ro     # Kernel log (connection tracking)
    networks:
      - default
    env_file:
      - .env
    environment:
      # Default settings (can be overridden in .env file)
      - GATEWAY_MODE=${GATEWAY_MODE:-false}
      - ALLOWED_SOURCES=${ALLOWED_SOURCES:-any}
    cap_add:
      - NET_ADMIN
      - SYS_ADMIN

networks:
  default:
    name: sidecar_net
```

3. **Create `.env`**:
```bash
# Backend mode (default)
ZT_NETWORK=your_zerotier_network_id_here
# Port forwarding: EXTERNAL_PORT:DEST_IP_OR_NAME:DEST_PORT
# You can use container names or IP addresses!
PORT_FORWARD=873:my-rsync-server:873,22:my-ssh-server:22
GATEWAY_MODE=false
```

### Gateway Mode (NEW!)

1. **Gateway Server - `docker-compose.yml`**:
```yaml
version: "3.8"

services:
  zerotier-gateway:
    image: alexbic/zerotier-sidecar:gateway
    container_name: zerotier-gateway
    restart: unless-stopped
    privileged: true
    devices:
      - /dev/net/tun:/dev/net/tun
    ports:
      - "8989:8989"  # Open to Internet
      - "443:443"    # HTTPS access
    volumes:
      - ./gateway-data:/var/lib/zerotier-one
    env_file:
      - .env
    cap_add:
      - NET_ADMIN
      - SYS_ADMIN
```

2. **Gateway Server - `.env`**:
```bash
# Gateway mode - accepts Internet traffic and forwards to ZeroTier
ZT_NETWORK=your_zerotier_network_id_here
PORT_FORWARD=8989:10.121.15.16:8989,443:10.121.15.20:443
GATEWAY_MODE=true
ALLOWED_SOURCES=203.0.113.0/24  # Your allowed source networks
```

3. **Backend Server - `.env`**:
```bash
# Backend mode - receives from ZeroTier and forwards to Docker
ZT_NETWORK=your_zerotier_network_id_here
# Use container names for easier configuration
PORT_FORWARD=8989:my-web-app:8080,443:my-api-service:443
GATEWAY_MODE=false
```

## ⚙️ Configuration

### Dependencies

- `getent` (part of glibc utilities) — used for name resolution via NSS (/etc/hosts and Docker embedded DNS). Present in Debian/Ubuntu based images.
- `iputils-ping` — fallback resolver when `getent` is not available. The resolver does a one-time lookup at container start.
- `dnsutils` (optional) — provides `host`/`dig` if you prefer DNS-only resolution; not required for default behavior.

Notes:
- The sidecar performs a one-time resolution of destination names from `PORT_FORWARD` at startup and then configures iptables/socat using resolved IPs. This ensures deterministic iptables rules and avoids repeated lookups.
- Avoid mounting or overwriting `/etc/resolv.conf` from outside unless you know what you're doing; the container tries to preserve Docker embedded DNS and will append external DNS (8.8.8.8) if missing to help ZeroTier planet lookups.

### Environment Variables

| Variable | Required | Description | Default | Example |
|----------|----------|-------------|---------|---------|
| `ZT_NETWORK` | ✅ | ZeroTier Network ID | - | `a03edd986708c010` |
| `PORT_FORWARD` | ✅ | Port forwarding rules | - | `8989:10.121.15.16:8989` |
| `GATEWAY_MODE` | ❌ | Operation mode | `false` | `false`, `true`, `hybrid` |
| `ALLOWED_SOURCES` | ❌ | Allowed source IPs | `any` | `203.0.113.0/24,10.0.0.0/8` |
| `FORCE_ZEROTIER_ROUTES` | ❌ | Custom ZeroTier routes | - | `192.168.1.0/24:10.121.15.50` |
| `LOG_CONNECTIONS` | ❌ | Connection logging mode | `false` | `off`, `simple`, `full` |

### Operation Modes

- **`GATEWAY_MODE=false`** (Backend): ZeroTier → Docker (traditional mode)
- **`GATEWAY_MODE=true`** (Gateway): Internet → ZeroTier (new mode)  
- **`GATEWAY_MODE=hybrid`** (Hybrid): Both directions simultaneously

### Port Forwarding Format

**Basic Format**: `EXTERNAL_PORT:DEST_IP_OR_NAME:DEST_PORT`

**Backend Mode Examples**:
```bash
# Using container names (recommended - easier to maintain)
PORT_FORWARD=873:my-rsync-server:873,22:my-ssh-server:22,80:my-web-app:8080

# Using IP addresses (works but less flexible)
PORT_FORWARD=873:172.26.0.3:873,22:172.26.0.4:22,80:172.26.0.5:8080
```

**Gateway Mode Examples**:
```bash
# Forward to ZeroTier IPs
PORT_FORWARD=8989:10.121.15.16:8989,443:10.121.15.20:443
```

**⚠️ IMPORTANT - Gateway Mode Port Exposure**:

In **Gateway Mode**, the **first port** in `PORT_FORWARD` (EXTERNAL_PORT) must be accessible to clients. There are two scenarios:

**Scenario 1: Direct Internet Access** (sidecar exposed to internet)
```yaml
services:
  zerotier-sidecar:
    image: alexbic/zerotier-sidecar:gateway
    ports:
      - "8989:8989"  # ✅ REQUIRED - published to host (0.0.0.0:8989)
      - "443:443"    # ✅ REQUIRED - published to host
    environment:
      - PORT_FORWARD=8989:10.121.15.16:8989,443:10.121.15.20:443
```

**Scenario 2: Behind Reverse Proxy** (nginx/traefik in front)
```yaml
services:
  zerotier-sidecar:
    image: alexbic/zerotier-sidecar:gateway
    expose:
      - "8989"  # ✅ Only expose to Docker network, NOT to host
    networks:
      - proxy_network  # ✅ MUST be in same network as proxy
    environment:
      - PORT_FORWARD=8989:10.121.15.16:8989

  nginx-proxy:
    image: nginx
    ports:
      - "80:80"  # Proxy publishes to internet
    networks:
      - proxy_network  # ✅ MUST be in same network as sidecar

networks:
  proxy_network:
```

**Key Differences**:
- **`ports:`** - Publishes to host (accessible from internet)
- **`expose:`** - Only accessible to containers in same network
- **Reverse proxy setup**: Sidecar and proxy **MUST share the same Docker network**

**Backend Mode** does NOT require port publishing - traffic flows through ZeroTier network internally.

**Container Name Resolution**:
- Container names are automatically resolved to IPs at startup
- Works with containers in the same Docker network
- Uses Docker's embedded DNS (127.0.0.11) for reliable resolution
- Falls back to system DNS if needed
- One-time resolution at container start ensures deterministic routing

### Advanced Routing (NEW!)

For complex network topologies where destinations are routed through ZeroTier:

```bash
# Route private networks through specific ZeroTier gateways
FORCE_ZEROTIER_ROUTES=192.168.1.0/24:10.121.15.50,10.0.0.0/16:10.121.15.100

# Example: Access corporate network through ZeroTier
PORT_FORWARD=3389:192.168.10.100:3389,22:192.168.20.50:22
FORCE_ZEROTIER_ROUTES=192.168.10.0/24:10.121.15.10,192.168.20.0/24:10.121.15.20
```

## 🔐 Security Considerations

### Network Security
- **Isolation**: Use dedicated Docker networks for different service tiers
- **Authorization**: Always authorize devices in ZeroTier Central
- **Firewall**: Automatic iptables rules with port scan protection
- **Source Control**: Use `ALLOWED_SOURCES` to restrict access

### Production Security Best Practices

**IMPORTANT**: In production environments, never expose sidecar ports directly to the internet. Always use a reverse proxy.

#### Recommended Architecture:
```
Internet → Reverse Proxy (80/443) → Internal Network → ZeroTier Sidecar → Services
          (nginx/traefik)            (Docker network)
```

#### Secure Deployment Example:
```yaml
# docker-compose.yml - PRODUCTION SETUP
version: "3.8"

services:
  # Reverse proxy - ONLY service exposed to internet
  nginx-proxy:
    image: nginx:alpine
    ports:
      - "80:80"
      - "443:443"    # ONLY these ports open to internet
    volumes:
      - ./nginx.conf:/etc/nginx/nginx.conf
    networks:
      - frontend
      - backend

  # ZeroTier Gateway - NO external ports exposed
  zerotier-gateway:
    image: alexbic/zerotier-sidecar:gateway
    container_name: zerotier-gateway
    privileged: true
    devices:
      - /dev/net/tun:/dev/net/tun
    # NO ports section - only internal access
    networks:
      - backend
    environment:
      - ZT_NETWORK=your_network_id
      - PORT_FORWARD=8989:10.121.15.16:8989
      - GATEWAY_MODE=true
      - ALLOWED_SOURCES=172.18.0.0/16  # Only from docker network

networks:
  frontend:
    driver: bridge
  backend:
    driver: bridge
```

#### Nginx Configuration Example:
```nginx
# nginx.conf
upstream zerotier_backend {
    server zerotier-gateway:8989;  # Internal container name:port
}

server {
    listen 80;
    server_name yourdomain.com;

    location / {
        proxy_pass http://zerotier_backend;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
```

#### Key Security Benefits:
- **Limited Attack Surface**: Only 80/443 exposed to internet
- **SSL Termination**: Handle certificates at proxy level
- **Request Filtering**: Filter malicious requests before they reach sidecar
- **Rate Limiting**: Implement rate limiting at proxy level
- **DDoS Protection**: Proxy can handle DDoS protection
- **Logging**: Centralized access logging

### Best Practices
- **Never expose sidecar ports directly** - always use reverse proxy
- Use `GATEWAY_MODE=hybrid` only for testing/debugging
- Implement ZeroTier flow rules for additional access control
- Regular security audits of exposed services
- Use strong authentication on target services
- Configure fail2ban or similar intrusion prevention
- Regular backup of ZeroTier configurations

## 📊 Monitoring and Troubleshooting

### Logging System (Enhanced in v2.2.0!)

ZeroTier Sidecar includes comprehensive logging for monitoring service health and tracking connections.

#### Connection Logging Modes (NEW in v2.2.0!)

Control connection logging output with the `LOG_CONNECTIONS` environment variable:

| Mode | Description | Use Case |
|------|-------------|----------|
| `off` / `false` | No connection logs in console | Production (minimal output) |
| `simple` | Connection logs with service names | Standard monitoring |
| `full` | Connections + iptables debug logs | Troubleshooting & debugging |

**Examples:**
```yaml
environment:
  - LOG_CONNECTIONS=simple  # Show connections: "10.121.15.69 → 172.22.0.3 (rsync-server):873"
  - LOG_CONNECTIONS=full    # Show connections + detailed iptables rule matching
  - LOG_CONNECTIONS=off     # Disable console output (logs still saved to file)
```

**Simple Mode Output** (recommended for production):
```
[Nov 13 01:15:42] 10.121.15.69 → 172.22.0.3 (rsync-server):873
[Nov 13 01:16:20] 192.168.1.100 → 10.121.15.16 (sonarr):8989
```

**Full Mode Output** (for troubleshooting):
```
[Nov 13 01:15:42] 10.121.15.69 → 172.22.0.3 (rsync-server):873
[DBG-FORWARD] IN=zthbm5kwdx OUT=docker0 SRC=10.121.15.69 DST=172.22.0.3 PROTO=TCP DPT=873
[DBG-NAT-PREROUTING] IN=zthbm5kwdx SRC=10.121.15.69 DST=10.121.15.15 PROTO=TCP DPT=873
```

#### Log Files

All logs are stored in `/var/log/zerotier-sidecar/` inside the container:

| Log File | Purpose | Content |
|----------|---------|---------|
| `monitor.log` | Service monitoring | Service status, health checks, rules restoration |
| `connections.log` | Connection tracking | New TCP connections with timestamps |

#### Log Features

- **🔍 Service Name Mapping** (NEW in v2.2.0): Displays container names in logs (`172.22.0.3 (rsync-server):873`)
- **📺 Real-time Console Output** (NEW in v2.2.0): Connection logs visible in `docker logs` with `LOG_CONNECTIONS=simple`
- **🎚️ Flexible Logging Levels** (NEW in v2.2.0): Three modes - off/simple/full for different use cases
- **📝 Original Config Display** (NEW in v2.2.0): Shows user-configured names, not resolved IPs
- **🔄 Automatic Log Rotation**: Max 10MB per file, keeps 5 historical files
- **⏱️ Timestamped Events**: All events include precise timestamps
- **📊 Health Checks**: Periodic status reports every 5 minutes
- **🔧 Auto-Recovery Logging**: Tracks service downs and restorations

#### Log Examples

**Monitor Log** (`/var/log/zerotier-sidecar/monitor.log`):
```
[2025-11-10 19:20:15] [INFO] Service monitor started (PID: 427)
[2025-11-10 19:20:15] [INFO] Monitoring 6 forward rules
[2025-11-10 19:20:45] [WARN] Service DOWN: rsync-server (172.22.0.3):873 (port 873)
[2025-11-10 19:21:15] [INFO] Service RESTORED: rsync-server (172.22.0.3):873 (port 873) - service is back online
[2025-11-10 19:22:30] [WARN] Rules missing for port 8989 -> sonarr (10.121.15.16):8989 - restoring...
[2025-11-10 19:22:31] [INFO] Rules RESTORED: port 8989 -> sonarr (10.121.15.16):8989
[2025-11-10 19:25:45] [INFO] Health check: All services healthy (6 rules checked, 1 total restorations)
```

**Connection Log** (`/var/log/zerotier-sidecar/connections.log`):
```
[2025-11-10 19:22:30] NEW CONNECTION: 10.121.15.10 -> 172.22.0.3:873 (port 873)
[2025-11-10 19:23:15] NEW CONNECTION: 203.0.113.50 -> 10.121.15.16:8989 (port 8989)
[2025-11-10 19:24:00] NEW CONNECTION: 10.121.15.20 -> 192.168.88.28:9999 (port 9999)
```

#### Accessing Logs

**Mount logs as volume** (recommended for production):
```yaml
services:
  zerotier-sidecar:
    image: alexbic/zerotier-sidecar:latest
    volumes:
      - zt-logs:/var/log/zerotier-sidecar  # Persist logs outside container

volumes:
  zt-logs:
```

**View logs in real-time**:
```bash
# Monitor service events
docker exec zerotier-sidecar tail -f /var/log/zerotier-sidecar/monitor.log

# Monitor connections
docker exec zerotier-sidecar tail -f /var/log/zerotier-sidecar/connections.log

# View all logs
docker exec zerotier-sidecar ls -lh /var/log/zerotier-sidecar/
```

**Copy logs to host**:
```bash
# Copy current logs
docker cp zerotier-sidecar:/var/log/zerotier-sidecar ./sidecar-logs

# Copy and analyze
docker exec zerotier-sidecar cat /var/log/zerotier-sidecar/monitor.log | grep "Service DOWN"
```

#### Monitoring Features

The service monitor (started automatically) provides:

- **Service Health Checks**: Verifies each forwarded service every 30 seconds
- **Automatic Recovery**: Restores missing iptables/socat rules automatically
- **Connection Tracking**: Logs new TCP connections (rate-limited: 3/min per port)
- **State Tracking**: Detects service state changes (up ↔ down)
- **Restoration Counter**: Tracks total number of rule restorations

#### Log Rotation

Logs are automatically rotated when they exceed 10MB:
- Keeps up to 5 historical files (`.1`, `.2`, `.3`, `.4`, `.5`)
- Oldest files are automatically deleted
- Rotation happens during monitoring checks (every 30 seconds)

### Check Container Status
```bash
# View container logs with mode information
docker logs zerotier-sidecar

# View service monitor logs
docker exec zerotier-sidecar tail -100 /var/log/zerotier-sidecar/monitor.log

# View connection logs
docker exec zerotier-sidecar tail -100 /var/log/zerotier-sidecar/connections.log

# Check configuration
docker exec zerotier-sidecar cat /tmp/zt-sidecar/config.json

# Check ZeroTier status
docker exec zerotier-sidecar zerotier-cli listnetworks

# Check network routes
docker exec zerotier-sidecar ip route show
```

### Verify Port Forwarding
```bash
# Check listening ports
docker exec zerotier-sidecar ss -tulpn

# Check iptables rules
docker exec zerotier-sidecar iptables -L -n -v
docker exec zerotier-sidecar iptables -t nat -L -n -v

# Check socat processes (Gateway mode)
docker exec zerotier-sidecar ps aux | grep socat
```

### Common Issues and Solutions

**Issue**: Gateway mode connections timeout
- **Check**: Ports are exposed in `docker-compose.yml` ports section
- **Check**: `GATEWAY_MODE=true` and destination is ZeroTier address
- **Check**: Firewall allows gateway ports on host

**Issue**: Backend mode not working
- **Check**: Target service is running on specified Docker network
- **Check**: ZeroTier client can reach sidecar IP
- **Check**: Devices are authorized in ZeroTier Central

**Issue**: Custom routes not working
- **Check**: `FORCE_ZEROTIER_ROUTES` format: `NETWORK:GATEWAY`
- **Check**: Gateway IP is reachable in ZeroTier network
- **Check**: Target network is properly configured

## 🔄 Migration from v1.x to v2.x

### Version History
- **v1.x Core** (Legacy): Backend-only mode - available via `core` and `v1.1.1` tags
- **v2.x Gateway** (Current): Full Gateway support with backward compatibility

### Backward Compatibility
All v1.x configurations work unchanged in v2.x:
```bash
# v1.x configuration (still works in v2.x)
ZT_NETWORK=your_network_id
PORT_FORWARD=873:172.26.0.3:873
# GATEWAY_MODE defaults to 'false' (backend mode)
```

### Upgrading to Gateway Features
```bash
# Add gateway functionality to existing setup
GATEWAY_MODE=true  # Enable gateway mode
ALLOWED_SOURCES=your.external.ip/32  # Restrict access
```

### Staying on v1.x Core
If you prefer to stay on the legacy backend-only version:
```bash
# Use core tag (points to v1.1.1)
docker pull alexbic/zerotier-sidecar:core

# Or use explicit version
docker pull alexbic/zerotier-sidecar:v1.1.1
```

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/AmazingFeature`)
3. Commit your changes (`git commit -m 'Add some AmazingFeature'`)
4. Push to the branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🙏 Acknowledgments

- [ZeroTier](https://zerotier.com) for the amazing network virtualization platform
- [Docker](https://docker.com) for containerization technology
- The open-source community for inspiration and support

## 📞 Support

- 🐛 **Issues**: [GitHub Issues](https://github.com/alexbic/zerotier-sidecar/issues)
- 💬 **Discussions**: [GitHub Discussions](https://github.com/alexbic/zerotier-sidecar/discussions)
- 📖 **Documentation**: Check this README and examples in repository

---

⭐ **If this project helped you, please give it a star!** ⭐
