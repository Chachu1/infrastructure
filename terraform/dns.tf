# Cloudflare DNS records for services with a domain
resource "cloudflare_dns_record" "service" {
  for_each = {
    for name, svc in local.services : name => svc
    if try(svc.domain, "") != ""
  }

  zone_id = var.cloudflare_zone_id
  name    = each.value.domain
  content = "168.119.81.167"
  type    = "A"
  proxied = true
}
