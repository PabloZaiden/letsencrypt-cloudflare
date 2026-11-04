#!/usr/bin/env bash
set +x
set -Eeuo pipefail
trap 'echo "ERROR: Certificate lifecycle failed at line $LINENO" >&2' ERR

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

[ -n "${CLOUDFLARE_API_TOKEN:-}" ] || fail "CLOUDFLARE_API_TOKEN is required"
[[ "$CLOUDFLARE_API_TOKEN" =~ ^[a-zA-Z0-9_-]+$ ]] ||
  fail "CLOUDFLARE_API_TOKEN contains unexpected characters"
[ -n "${LETSENCRYPT_DOMAIN:-}" ] || fail "LETSENCRYPT_DOMAIN is required"
DOMAIN="$LETSENCRYPT_DOMAIN"
[[ ${#DOMAIN} -le 253 && "$DOMAIN" = *.* ]] ||
  fail "LETSENCRYPT_DOMAIN must be a base domain without wildcards"
IFS=. read -r -a LABELS <<< "$DOMAIN"
for LABEL in "${LABELS[@]}"; do
  [[ ${#LABEL} -le 63 && "$LABEL" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] ||
    fail "LETSENCRYPT_DOMAIN must be a lowercase base domain without wildcards"
done
[[ "$DOMAIN" != *. ]] || fail "LETSENCRYPT_DOMAIN must not have a trailing dot"

TESTING="${TESTING:-false}"
WILDCARD="${LETSENCRYPT_WILDCARD:-false}"
for BOOLEAN in "$TESTING" "$WILDCARD"; do
  [[ "$BOOLEAN" = true || "$BOOLEAN" = false ]] ||
    fail "TESTING and LETSENCRYPT_WILDCARD must be true or false"
done
if [ "$TESTING" = true ] && [ -n "${KUBERNETES_SECRET:-}" ] &&
   [[ "$KUBERNETES_SECRET" != *-staging ]]; then
  fail "TESTING=true requires a KUBERNETES_SECRET ending in -staging (or no Kubernetes Secret)"
fi

PROPAGATION_SECONDS="${CLOUDFLARE_PROPAGATION_SECONDS:-60}"
[[ "$PROPAGATION_SECONDS" =~ ^[0-9]+$ ]] ||
  fail "CLOUDFLARE_PROPAGATION_SECONDS must be a non-negative integer"
OWNER_UID="$(printenv UID || printf '0')"
OWNER_GID="${GID:-0}"
[[ "$OWNER_UID" =~ ^[0-9]+$ && "$OWNER_GID" =~ ^[0-9]+$ ]] ||
  fail "UID and GID must be non-negative integers"
KUBECTL="${KUBECTL:-kubectl}"
CONFIG_DIR="${LETSENCRYPT_CONFIG_DIR:-/etc/letsencrypt}"
if [ "$TESTING" = true ]; then
  CONFIG_DIR="$CONFIG_DIR/staging"
fi
mkdir -p "$CONFIG_DIR"
(
  umask 077
  printf 'dns_cloudflare_api_token = %s\n' "$CLOUDFLARE_API_TOKEN" > "$CONFIG_DIR/cloudflare.ini"
  chmod 600 "$CONFIG_DIR/cloudflare.ini"
)

CERTBOT_ARGS=(--config-dir "$CONFIG_DIR" --work-dir "$CONFIG_DIR/work"
  --logs-dir "$CONFIG_DIR/logs" --non-interactive)
DOMAIN_ARGS=(-d "$DOMAIN")
if [ "$WILDCARD" = true ]; then
  DOMAIN_ARGS+=(-d "*.$DOMAIN")
fi
ISSUE_ARGS=(--cert-name "$DOMAIN" --agree-tos --keep-until-expiring)
if [ -n "${LETSENCRYPT_EMAIL:-}" ]; then
  ISSUE_ARGS+=(--email "$LETSENCRYPT_EMAIL")
else
  echo "WARNING: LETSENCRYPT_EMAIL is not set" >&2
  ISSUE_ARGS+=(--register-unsafely-without-email)
fi
if [ "$TESTING" = true ]; then
  ISSUE_ARGS+=(--test-cert)
fi

echo "INFO: Issuing Cloudflare DNS-01 certificate for $DOMAIN (staging=$TESTING)"
certbot certonly "${CERTBOT_ARGS[@]}" "${ISSUE_ARGS[@]}" \
  --dns-cloudflare --dns-cloudflare-credentials "$CONFIG_DIR/cloudflare.ini" \
  --dns-cloudflare-propagation-seconds "$PROPAGATION_SECONDS" "${DOMAIN_ARGS[@]}"

CERT_DIR="$CONFIG_DIR/live/$DOMAIN"
publish_certificate() {
  [ -s "$CERT_DIR/fullchain.pem" ] && [ -s "$CERT_DIR/privkey.pem" ] ||
    fail "Certificate files are missing in $CERT_DIR"
  chown -R "$OWNER_UID:$OWNER_GID" "$CONFIG_DIR"
  if [ -n "${KUBERNETES_SECRET:-}" ]; then
    echo "INFO: Updating Kubernetes Secret $KUBERNETES_SECRET"
    "$KUBECTL" create secret tls "$KUBERNETES_SECRET" \
      --save-config \
      --cert="$CERT_DIR/fullchain.pem" \
      --key="$CERT_DIR/privkey.pem" \
      --dry-run=client -o yaml | "$KUBECTL" apply -f -
  fi
}

publish_certificate
while :; do
  DELAY_SECONDS="$(($(shuf -i 1-720 -n 1) * 60))"
  echo "INFO: Checking renewal in $DELAY_SECONDS seconds"
  sleep "$DELAY_SECONDS"
  certbot renew "${CERTBOT_ARGS[@]}" --cert-name "$DOMAIN"
  publish_certificate
done
