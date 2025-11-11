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

# Слой 1: Обновление apt кеша (кешируется долго)
RUN apt-get update

# Слой 2: Установка curl (необходим для ZeroTier)
RUN apt-get install -y --no-install-recommends curl && \
    rm -rf /var/lib/apt/lists/*

# Слой 3: Установка базовых сетевых утилит
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        iproute2 \
        iptables \
        iputils-ping \
        procps && \
    rm -rf /var/lib/apt/lists/*

# Слой 4: Установка утилит для проксирования
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        netcat-openbsd \
        socat && \
    rm -rf /var/lib/apt/lists/*

# Слой 5: Установка системы логирования
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ulogd2 \
        iptables-persistent && \
    rm -rf /var/lib/apt/lists/*

# Слой 6: Установка ZeroTier
RUN curl -s https://install.zerotier.com | bash && \
    service zerotier-one stop || true && \
    rm -rf /var/lib/zerotier-one/identity.* /var/lib/zerotier-one/*.secret /var/lib/zerotier-one/*.pid

# Слой 7: Копирование конфигурационных файлов
COPY ulogd.conf /etc/ulogd.conf

# Слой 8: Копирование и установка прав на скрипт
COPY start-sidecar.sh /usr/local/bin/start-sidecar.sh
RUN chmod +x /usr/local/bin/start-sidecar.sh

ENTRYPOINT ["/usr/local/bin/start-sidecar.sh"]
