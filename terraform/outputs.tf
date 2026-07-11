# Outputs for Ansible inventory generation
output "ansible_inventory" {
  description = "Ansible inventory in YAML format"
  value = yamlencode({
    all = {
      children = {
        gateway = {
          hosts = {
            gateway = {
              ansible_host = "10.0.0.10"
              ansible_user = "root"
            }
          }
        }
        apps = {
          hosts = {
            for name, svc in local.services : name => {
              ansible_host = split("/", svc.ip)[0]
              ansible_user = "root"
            } if name != "gateway"
          }
        }
      }
    }
  })
}

output "gateway_ip" {
  description = "Gateway LXC IP address"
  value       = split("/", local.services.gateway.ip)[0]
}

output "app_ips" {
  description = "Application LXC IP addresses"
  value = {
    for name, svc in local.services : name => split("/", svc.ip)[0]
    if name != "gateway"
  }
}
