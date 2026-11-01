# FlareSolverr (Docker host)

FlareSolverr solves Cloudflare managed challenges for retailers whose pages
reject patchright (currently **Swas / swsg.co** and **Lulu / luluhypermarket.com**).

## Where it runs

- Host: docker host `192.168.1.207` (home LAN, residential egress)
- Bind: `192.168.1.207:8191`
- Compose project on the host: `/opt/price-tracker/docker/flaresolverr/docker-compose.yml`
- Consumer: `local-scraper` LXC (`10.0.0.68`), via `FLARESOLVERR_URL`

The local-scraper reaches the docker host through the gateway route
(`10.0.0.68 -> 10.0.0.10 -> 192.168.1.207`), the same path already used for the
SOCKS5 proxy on port 1080.

## Deploy / update

```bash
ssh docker
mkdir -p /opt/price-tracker/docker/flaresolverr
# copy this compose file to that path
cd /opt/price-tracker/docker/flaresolverr
docker compose up -d
```

## Smoke test

```bash
curl -sS -X POST http://192.168.1.207:8191/v1 \
  -H 'Content-Type: application/json' \
  -d '{"cmd":"request.get","url":"https://swsg.co/en/tvs-audios/tvs.html?product_list_limit=320","maxTimeout":120000}' \
  | jq -r '.status, .solution.status'
```

Expected: `ok`, `200`.

## Notes

- The request takes 10-30s while the challenge is solved; the local-scraper
  uses a 120s `maxTimeout` and a 135s socket timeout.
- `local-scraper` still applies its PostgreSQL rate limiter around proxy-backed
  FlareSolverr calls.
- If Swas/Lulu start getting challenged even through FlareSolverr, the egress
  IP is flagged; route FlareSolverr through a residential proxy instead of
  changing the scraper.
