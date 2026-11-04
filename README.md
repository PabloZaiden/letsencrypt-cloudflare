# Let's Encrypt with Cloudflare DNS and Kubernetes

A small wrapper around the official
[`certbot/dns-cloudflare`](https://hub.docker.com/r/certbot/dns-cloudflare)
image. Certbot and its official Cloudflare plugin issue/renew the certificates;
this wrapper schedules renewal checks and optionally publishes the files to an
existing Kubernetes TLS Secret.

This repository is Cloudflare-only and independent of `letsencrypt-duckdns`.
It does not update public IP records, run a reverse proxy, or install cert-manager.
Use a separate DDNS container such as
[`favonia/cloudflare-ddns`](https://github.com/favonia/cloudflare-ddns) for IP changes.

## Requirements

- Your own domain, with authoritative DNS hosted on Cloudflare.
- A Cloudflare API Token restricted to that zone with **Zone / DNS / Edit** and
  **Zone / Zone / Read** permissions. Do not use the Global API Key.
- Persistent `/etc/letsencrypt` storage for the account, certificates and renewal
  configuration.
- If publishing to Kubernetes: a ServiceAccount with permission to get, create,
  patch and update Secrets in the target namespace. `kubectl` uses its in-cluster
  credentials and the pod's namespace.

DNS-01 validation does not require opening inbound port 80. The token can be
shared with a separate Cloudflare DDNS container.

## Environment

| Variable | Default | Description |
| --- | --- | --- |
| `CLOUDFLARE_API_TOKEN` | required | Zone-scoped Cloudflare API Token |
| `LETSENCRYPT_DOMAIN` | required | Lowercase base domain, e.g. `home.example.com` |
| `LETSENCRYPT_WILDCARD` | `false` | Also request `*.home.example.com`; always includes the base name |
| `LETSENCRYPT_EMAIL` | unset | ACME account contact email |
| `CLOUDFLARE_PROPAGATION_SECONDS` | `60` | DNS-01 propagation wait |
| `TESTING` | `false` | Use Let's Encrypt staging (not browser-trusted) |
| `KUBERNETES_SECRET` | unset | TLS Secret to create/update; omit to only write files |
| `LETSENCRYPT_CONFIG_DIR` | `/etc/letsencrypt` | Persistent certificate storage directory |
| `UID`, `GID` | `0`, `0` | Certificate file ownership; the container itself starts as root |

`TESTING` and `LETSENCRYPT_WILDCARD` accept only `true` or `false`. Staging uses a
separate `/etc/letsencrypt/staging` directory. When testing with Kubernetes,
`KUBERNETES_SECRET` must end in `-staging` to avoid overwriting the production
Secret. Do not configure production ingress to use that staging Secret.

The token is never logged. Certbot needs it for renewals, so it is written to a
mode-600 credentials file on the persistent volume and refreshed at startup.
Protect that volume and its backups, which also contain private keys. After
rotating a Kubernetes Secret token, restart this deployment to read the new value.

## Standalone staging test

Provide the three required token/domain/email environment variables through a
secure local mechanism, then run:

```bash
docker compose up
```

The included Compose example requests an untrusted staging certificate and does
not access Kubernetes. Certificates appear under
`./certs/staging/live/<domain>/`. Change `TESTING` to `'false'` for production;
production files live under `./certs/live/<domain>/`.

For reproducible deployments, pin an image digest rather than a moving `:main`
tag.

## homeserver-kubernetes workload

```yaml
name: letsencrypt-cloudflare
serviceAccount: secret-updater
image: ghcr.io/pablozaiden/letsencrypt-cloudflare:main
env:
  TESTING: 'false'
  UID: '1000'
  GID: '1000'
  LETSENCRYPT_WILDCARD: 'true'
  LETSENCRYPT_EMAIL: $LETSENCRYPT_EMAIL
  LETSENCRYPT_DOMAIN: $CLUSTER_DOMAIN
  KUBERNETES_SECRET: $CLUSTER_DOMAIN
secrets:
  CLOUDFLARE_API_TOKEN:
    secretName: cloudflare
    secretKey: token
mounts:
  - /etc/letsencrypt
```

This preserves the existing `secret-updater` ServiceAccount and TLS Secret naming.
Use a separate volume/directory from an old certificate container for rollback.
The base name plus wildcard cover one subdomain level, not
`app.internal.home.example.com`.

Certificates are published immediately after initial issuance and each successful
renewal check, scheduled randomly within twelve hours. Only the configured
domain's lineage is renewed. Issuance, renewal, missing certificate files and
Kubernetes publication errors exit non-zero so the runtime can restart the
container.

## Build and regression tests

```bash
node --test tests/*.test.mjs
docker build -t letsencrypt-cloudflare .
```

Node tests mock external commands and require no credentials or ACME access.
CI also builds/runs the actual container. Pushes to `main` publish Linux amd64 and
arm64 images at `ghcr.io/pablozaiden/letsencrypt-cloudflare:main` and immutable
`sha-<commit>` tags; pull requests do not publish.

The official base image is pinned by version and digest. `KUBECTL_VERSION` is a
pinned build argument; choose a version within one minor version of your
Kubernetes API server when updating/building it.

The renewal/Secret-publication wrapper is adapted from the author's
MIT-licensed `letsencrypt-duckdns` project; Cloudflare validation is provided by
the upstream official plugin, not reimplemented here.
