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
        lxc_apps = {
          hosts = {
            for name, svc in local.services : name => {
              ansible_host = split("/", svc.ip)[0]
              ansible_user = "root"
            } if name != "gateway" && try(svc.type, "lxc") == "lxc"
          }
        }
        vm_apps = {
          hosts = {
            for name, svc in local.services : name => {
              ansible_host = split("/", svc.ip)[0]
              ansible_user = "root"
            } if try(svc.type, "lxc") == "vm"
          }
        }
        apps = {
          children = {
            lxc_apps = {}
            vm_apps  = {}
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
  description = "Application LXC and VM IP addresses"
  value = merge(
    { for name, svc in local.services : name => split("/", svc.ip)[0]
      if name != "gateway" && try(svc.type, "lxc") == "lxc" },
    { for name, svc in local.services : name => split("/", svc.ip)[0]
      if try(svc.type, "lxc") == "vm" }
  )
}

output "services" {
  description = "Service definitions for Ansible (domain, backend_ip, port)"
  value = {
    for name, svc in local.services : name => {
      domain     = svc.domain
      backend_ip = split("/", svc.ip)[0]
      port       = svc.port
      scheme     = try(svc.scheme, "http")
    } if try(svc.domain, "") != ""
  }
}
