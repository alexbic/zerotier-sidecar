FROM ubuntu:22.04

# Устанавливаем необходимые пакеты
RUN apt-get update && \
    apt-get install -y \
        curl \
        iproute2 \
        iptables \
        iputils-ping \
        procps \
        telnet \
        net-tools && \
    rm -rf /var/lib/apt/lists/*

# Установка ZeroTier
RUN curl -s https://install.zerotier.com | bash

# Копируем стартовый скрипт
COPY start-sidecar.sh /usr/local/bin/start-sidecar.sh
RUN chmod +x /usr/local/bin/start-sidecar.sh

# Запуск
ENTRYPOINT ["/usr/local/bin/start-sidecar.sh"]
