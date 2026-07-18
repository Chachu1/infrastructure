# Cloudflare DNS records for services with a domain
resource "cloudflare_record" "service" {
  for_each = {
    for name, svc in local.services : name => svc
    if try(svc.domain, "") != ""
  }

  zone_id         = var.cloudflare_zone_id
  name            = each.value.domain
  value           = "168.119.81.167"
  type            = "A"
  proxied         = true
  allow_overwrite = true
}

# App domains for services with app routing (Traefik behind Caddy)
resource "cloudflare_record" "app_domains" {
  for_each = merge([
    for name, svc in local.services : {
      for d in try(svc.app_domains, []) : "${name}-${d}" => d
    } if try(svc.app_domains, []) != []
  ]...)

  zone_id         = var.cloudflare_zone_id
  name            = each.value
  value           = "168.119.81.167"
  type            = "A"
  proxied         = true
  allow_overwrite = true
}

# Wildcard domains for future service routing
resource "cloudflare_record" "wildcard_domains" {
  for_each = {
    for name, svc in local.services : name => svc.wildcard_domain
    if try(svc.wildcard_domain, "") != ""
  }

  zone_id         = var.cloudflare_zone_id
  name            = each.value
  value           = "168.119.81.167"
  type            = "A"
  proxied         = true
  allow_overwrite = true
}
