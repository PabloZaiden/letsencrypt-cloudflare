FROM certbot/dns-cloudflare:v5.9.0@sha256:8216d4732d11772a9cf2fb30d022abf9eec7c83af2e33f002aa9e371c5192b67

LABEL org.opencontainers.image.source="https://github.com/PabloZaiden/letsencrypt-cloudflare"

ARG TARGETARCH
ARG KUBECTL_VERSION=v1.37.2

RUN apk add --no-cache bash curl \
    && curl --fail --silent --show-error --location \
        "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
        --output /usr/local/bin/kubectl \
    && curl --fail --silent --show-error --location \
        "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl.sha256" \
        --output /tmp/kubectl.sha256 \
    && echo "$(cat /tmp/kubectl.sha256)  /usr/local/bin/kubectl" | sha256sum -c - \
    && rm /tmp/kubectl.sha256 \
    && chmod 755 /usr/local/bin/kubectl \
    && kubectl version --client \
    && certbot plugins --authenticators | grep -q dns-cloudflare

COPY scripts/start.sh /usr/local/bin/start.sh

ENTRYPOINT ["/bin/bash", "/usr/local/bin/start.sh"]
CMD []
