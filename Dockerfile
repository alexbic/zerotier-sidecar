FROM ubuntu:22.04

# OCI Image Labels - https://github.com/opencontainers/image-spec/blob/main/annotations.md
LABEL org.opencontainers.image.title="ZeroTier Sidecar" \
      org.opencontainers.image.description="ZeroTier network bridge for Docker with three modes: Backend (ZeroTier→containers), Gateway (Internet→ZeroTier), Hybrid (both). Supports container name resolution and flexible port forwarding." \
      org.opencontainers.image.authors="Alexander Bikmukhametov <alex_bic@mac.com>" \
      org.opencontainers.image.vendor="Alexander Bikmukhametov" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.url="https://github.com/alexbic/zerotier-sidecar" \
      org.opencontainers.image.source="https://github.com/alexbic/zerotier-sidecar" \
      org.opencontainers.image.documentation="https://github.com/alexbic/zerotier-sidecar#readme"

RUN apt-get update && \
    apt-get install -y \
        curl \
        iproute2 \
        iptables \
        iputils-ping \
            dnsutils \
        procps \
        telnet \
        net-tools \
        socat && \
    rm -rf /var/lib/apt/lists/*

# Установка ZeroTier
RUN curl -s https://install.zerotier.com | bash

COPY start-sidecar.sh /usr/local/bin/start-sidecar.sh
RUN chmod +x /usr/local/bin/start-sidecar.sh

ENTRYPOINT ["/usr/local/bin/start-sidecar.sh"]
