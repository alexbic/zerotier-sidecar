# 🌐 ZeroTier Sidecar Core

[![Docker Pulls](https://img.shields.io/docker/pulls/alexbic/zerotier-sidecar)](https://hub.docker.com/r/alexbic/zerotier-sidecar)
[![Docker Image Size](https://img.shields.io/docker/image-size/alexbic/zerotier-sidecar/latest)](https://hub.docker.com/r/alexbic/zerotier-sidecar)
[![License](https://img.shields.io/github/license/alexbic/zerotier-sidecar)](LICENSE)
[![GitHub Stars](https://img.shields.io/github/stars/alexbic/zerotier-sidecar)](https://github.com/alexbic/zerotier-sidecar/stargazers)

🇺🇸 English | [🇷🇺 Русский](README.ru.md)

A powerful Docker container that acts as a ZeroTier network bridge, enabling secure port forwarding from ZeroTier networks to Docker containers. Perfect for accessing internal services remotely through ZeroTier's secure network mesh.

## 🐳 Docker Images

Docker images are available on both **Docker Hub** and **GitHub Container Registry**:

**Docker Hub**: [`alexbic/zerotier-sidecar`](https://hub.docker.com/r/alexbic/zerotier-sidecar)
```bash
docker pull alexbic/zerotier-sidecar:latest
```

**GitHub Container Registry**: [`ghcr.io/alexbic/zerotier-sidecar`](https://github.com/alexbic/zerotier-sidecar/pkgs/container/zerotier-sidecar)
```bash
docker pull ghcr.io/alexbic/zerotier-sidecar:latest
```

## 🚀 Features

- **🔐 Secure Port Forwarding**: Flexible port mapping from ZeroTier network to Docker containers through encrypted connection
- **📦 Easy Deployment**: Single Docker container with simple configuration
- **🌐 ZeroTier & Docker Integration**: Seamless bridge between ZeroTier networks and Docker containers
- **🏷️ Container Name Resolution**: Use container names instead of IPs in port forwarding rules
- **🔍 Smart DNS Management**: Preserves Docker embedded DNS for seamless service discovery

## 🎯 Use Cases

- **🏠 Home Lab Access**: Access your home services securely from anywhere
- **💾 Remote Backup**: Enable rsync, NAS, or backup services over ZeroTier
- **🖥️ Development**: Access development environments remotely
- **🔧 System Administration**: Remote SSH and service management
- **📡 IoT Connectivity**: Connect IoT devices and services across networks

## 📋 Quick Start

### Using Docker Compose (Recommended)

1. **Create project directory**:
```bash
mkdir zerotier-sidecar && cd zerotier-sidecar
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
    cap_add:
      - NET_ADMIN
      - SYS_ADMIN

networks:
  default:
    name: sidecar_net
```

3. **Create `.env`**:
```bash
# Your ZeroTier Network ID
ZT_NETWORK=your_zerotier_network_id_here

# Port forwarding: EXTERNAL_PORT:DEST_IP_OR_NAME:DEST_PORT
# Multiple ports separated by comma
# You can use container names or IP addresses!
PORT_FORWARD=873:my-rsync-server:873,22:my-ssh-server:22
# Or with IPs: PORT_FORWARD=873:172.26.0.3:873,22:172.26.0.4:22
```

4. **Deploy**:
```bash
docker-compose up -d
```

### Using Docker Run

```bash
docker run -d \
  --name zerotier-sidecar \
  --privileged \
  --device /dev/net/tun \
  --restart unless-stopped \
  --cap-add NET_ADMIN \
  --cap-add SYS_ADMIN \
  -e ZT_NETWORK=your_network_id \
  -e PORT_FORWARD=873:my-service:873 \
  -v zerotier-data:/var/lib/zerotier-one \
  alexbic/zerotier-sidecar:latest
```

## ⚙️ Configuration

### Environment Variables

| Variable | Required | Description | Example |
|----------|----------|-------------|---------|
| `ZT_NETWORK` | ✅ | ZeroTier Network ID | `your_zerotier_network_id_here` |
| `PORT_FORWARD` | ✅ | Port forwarding rules | `873:172.26.0.3:873,22:172.26.0.4:22` |

### Port Forwarding Format

The `PORT_FORWARD` variable uses the format: `EXTERNAL_PORT:DEST_IP_OR_NAME:DEST_PORT`

- **EXTERNAL_PORT**: Port accessible from ZeroTier network
- **DEST_IP_OR_NAME**: Target Docker container IP or container name
- **DEST_PORT**: Target container port

**Examples**:
- Using container names (recommended): `873:my-rsync-server:873,22:my-ssh-server:22`
- Using IPs: `873:172.26.0.3:873,22:172.26.0.4:22`
- Mixed: `873:my-service:873,22:172.26.0.4:22,80:nginx:8080`

**Container Name Resolution**:
- Container names are automatically resolved to IPs at startup
- Works with containers in the same Docker network
- Uses Docker's embedded DNS (127.0.0.11) for reliable resolution
- Falls back to system DNS if needed

## 🔧 Setup Guide

### 1. Create ZeroTier Network

1. Go to [ZeroTier Central](https://my.zerotier.com)
2. Create a new network
3. Note your Network ID (16-character hex string)
4. Configure network settings as needed

### 2. Configure Target Services

Ensure your target Docker services are in the same network as the sidecar:

```yaml
# Your service docker-compose.yml
version: "3.8"
services:
  my-service:
    image: my-service:latest
    networks:
      sidecar_net:
        external: true
```

### 3. Deploy and Test

```bash
# Deploy the sidecar
docker-compose up -d

# Check logs
docker-compose logs -f

# Test connectivity from ZeroTier network
ping SIDECAR_ZEROTIER_IP
telnet SIDECAR_ZEROTIER_IP 873
```

## 📊 Monitoring and Troubleshooting

### Check Container Status

```bash
# View logs
docker logs zerotier-sidecar

# Access container shell
docker exec -it zerotier-sidecar bash

# Check ZeroTier status
docker exec zerotier-sidecar zerotier-cli listnetworks

# Check network configuration
docker exec zerotier-sidecar ip addr show
```

### Common Issues

**Issue**: `join connection failed`
- **Solution**: Check internet connectivity and firewall settings

**Issue**: Port forwarding not working
- **Solution**: Verify target service IP and ensure services are in same Docker network

**Issue**: Can't reach ZeroTier IP
- **Solution**: Ensure device is authorized in ZeroTier Central

## 🏗️ Architecture

```
┌─────────────────┐    ZeroTier     ┌─────────────────┐
│   Remote Client │◄──────────────►│  Sidecar        │
│  (Home/Office)  │                │  Container      │
└─────────────────┘                └─────────────────┘
                                            │
                                   Docker Network
                                            │
                                   ┌─────────────────┐
                                   │  Target Service │
                                   │  (rsync/ssh/etc)│
                                   └─────────────────┘
```

## 🔐 Security Considerations

- **Network Isolation**: Use dedicated Docker networks for better security
- **ZeroTier Authorization**: Always authorize devices in ZeroTier Central
- **Firewall Rules**: Configure appropriate firewall rules for target services
- **Access Control**: Use ZeroTier's flow rules for additional access control

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

---

⭐ **If this project helped you, please give it a star!** ⭐
