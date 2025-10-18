FROM ubuntu:22.04

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
