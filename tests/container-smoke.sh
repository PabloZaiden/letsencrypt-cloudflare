#!/usr/bin/env bash
set -Eeuo pipefail

IMAGE="${1:-letsencrypt-cloudflare:test}"
WORK_DIR="$(mktemp -d)"
cleanup() {
  rm -f -- "$WORK_DIR/certbot" "$WORK_DIR/kubectl" "$WORK_DIR/sleep"
  rmdir -- "$WORK_DIR"
}
trap cleanup EXIT

cat > "$WORK_DIR/certbot" <<'EOF'
#!/bin/sh
set -eu
config=""
name=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --config-dir) config="$2"; shift ;;
    --cert-name) name="$2"; shift ;;
  esac
  shift
done
mkdir -p "$config/live/$name"
printf 'dummy-cert' > "$config/live/$name/fullchain.pem"
printf 'dummy-key' > "$config/live/$name/privkey.pem"
EOF
cat > "$WORK_DIR/kubectl" <<'EOF'
#!/bin/sh
set -eu
if [ "$1" = create ]; then
  printf 'dummy-tls-secret'
else
  value="$(cat)"
  [ "$value" = dummy-tls-secret ]
  echo 'TLS Secret publication verified'
fi
EOF
cat > "$WORK_DIR/sleep" <<'EOF'
#!/bin/sh
exit 99
EOF
chmod 755 "$WORK_DIR/certbot" "$WORK_DIR/kubectl" "$WORK_DIR/sleep"

set +e
OUTPUT="$(docker run --rm \
  --mount "type=bind,src=$WORK_DIR,dst=/mocks,readonly" \
  --env PATH=/mocks:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
  --env CLOUDFLARE_API_TOKEN=container-test-placeholder \
  --env LETSENCRYPT_DOMAIN=home.example.com \
  --env LETSENCRYPT_EMAIL=owner@example.com \
  --env LETSENCRYPT_WILDCARD=true \
  --env TESTING=true \
  --env KUBERNETES_SECRET=home.example.com-staging \
  --env UID=1000 --env GID=1000 \
  "$IMAGE" 2>&1)"
STATUS=$?
set -e
printf '%s\n' "$OUTPUT"
test "$STATUS" -eq 99
grep -q 'TLS Secret publication verified' <<< "$OUTPUT"
if grep -q container-test-placeholder <<< "$OUTPUT"; then
  echo 'ERROR: Token appeared in container output' >&2
  exit 1
fi
