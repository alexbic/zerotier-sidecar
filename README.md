# 🌐 ZeroTier Sidecar Gateway v2.0

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
# Pull the gateway-enabled version
docker pull alexbic/zerotier-sidecar:gateway

# Or use latest tag (points to gateway)
docker pull alexbic/zerotier-sidecar:latest
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
      - ./sidecar-data:/var/lib/zerotier-one
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

In **Gateway Mode**, the **first port** in `PORT_FORWARD` (EXTERNAL_PORT) **MUST be published** in the `ports:` section of `docker-compose.yml`. Otherwise, internet clients won't be able to connect!

**Example**:
```yaml
# In docker-compose.yml:
ports:
  - "8989:8989"  # ✅ REQUIRED - matches PORT_FORWARD first port
  - "443:443"    # ✅ REQUIRED - matches PORT_FORWARD first port

# In .env:
PORT_FORWARD=8989:10.121.15.16:8989,443:10.121.15.20:443
```

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

### Check Container Status
```bash
# View logs with mode information
docker logs zerotier-sidecar

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
