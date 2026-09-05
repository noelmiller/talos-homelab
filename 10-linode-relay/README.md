# Linode game relay

This Terraform stack creates a `$5/month` Nanode in Linode's Chicago region
with a deny-by-default Cloud Firewall. The VM enables IPv4 forwarding,
installs Tailscale, and configures nftables to forward public game traffic to
the pfSense Tailscale subnet router.

## Permitted inbound ports

| Port | Protocol | Purpose |
|---:|:---:|---|
| 22 | TCP | SSH, restricted to `admin_cidr` |
| 41641 | UDP | Tailscale direct connections |
| 25565 | TCP | Minecraft survival Java |
| 19132 | UDP | Minecraft survival Bedrock |
| 25566 | TCP | Minecraft creative Java |
| 19133 | UDP | Minecraft creative Bedrock |
| 8211 | UDP | Palworld gameplay |
| 27015 | UDP | Palworld community discovery |

Palworld's REST API on `8212/TCP`, Minecraft RCON, Kubernetes, and homelab
management services remain closed.

## Authentication

Terraform reads a Linode token from `LINODE_TOKEN`. Create a restricted
Personal Access Token with read/write access to Linodes and firewalls, then
export it before running Terraform:

```bash
export LINODE_TOKEN='<personal-access-token>'
```

The Linode CLI OAuth token can also be used locally without printing it:

```bash
export LINODE_TOKEN="$(
  sed -n '/^\[noelmiller\]$/,/^\[/s/^token[[:space:]]*=[[:space:]]*//p' \
    ~/.config/linode-cli | head -1
)"
```

## Deploy

```bash
cd 10-linode-relay
cp terraform.tfvars.example terraform.tfvars
curl -4 https://ifconfig.me
terraform init
terraform plan
terraform apply
```

Set `admin_cidr` to the returned public address with `/32`. Terraform protects
the VM from accidental destruction. To intentionally remove it, temporarily
set `prevent_destroy = false`, apply that change, and then run
`terraform destroy`.

## Tailscale

Configure the pfSense Tailscale package to advertise `10.42.0.0/24`, approve
that route in the Tailscale admin console, and then authorize the relay:

```bash
ssh root@$(terraform output -raw relay_public_ip)
tailscale up --accept-routes --hostname=game-relay --ssh=false
```

The relay's nftables rules forward these public ports through Tailscale:

| Public port | Tailscale-routed destination |
|---:|---|
| `25565/TCP` | `10.42.0.12:25565` |
| `19132/UDP` | `10.42.0.12:19132` |
| `25566/TCP` | `10.42.0.13:25566` |
| `19133/UDP` | `10.42.0.13:19133` |
| `8211/UDP` | `10.42.0.14:8211` |
| `27015/UDP` | `10.42.0.14:27015` |

Keep the relay node and pfSense route approval active in the Tailscale admin
console. Tailscale authentication is intentionally not stored in Terraform or
cloud-init.

Point DNS-only game records at the `relay_public_ip` output after forwarding
works. The public IPv4 remains stable for the life of the Linode.
