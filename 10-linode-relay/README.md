# Linode game relay

This Terraform stack creates a `$5/month` Nanode in Linode's Chicago region
with a deny-by-default Cloud Firewall. The VM is prepared for WireGuard and
IPv4 forwarding but does not configure the WireGuard peer or packet-forwarding
rules, which must be paired with pfSense.

## Permitted inbound ports

| Port | Protocol | Purpose |
|---:|:---:|---|
| 22 | TCP | SSH, restricted to `admin_cidr` |
| 51820 | UDP | WireGuard |
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

## Next step

After deployment, configure `wg0` on the VM and pfSense, enable
`wg-quick@wg0`, and add nftables DNAT rules:

| Public port | WireGuard destination |
|---:|---|
| `25565/TCP` | `10.42.0.12:25565` |
| `19132/UDP` | `10.42.0.12:19132` |
| `25566/TCP` | `10.42.0.13:25566` |
| `19133/UDP` | `10.42.0.13:19133` |
| `8211/UDP` | `10.42.0.14:8211` |
| `27015/UDP` | `10.42.0.14:27015` |

Point DNS-only game records at the `relay_public_ip` output after forwarding
works. The public IPv4 remains stable for the life of the Linode.
