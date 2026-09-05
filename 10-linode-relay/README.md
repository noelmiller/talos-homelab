# Linode game relay

This Terraform stack creates a `$5/month` Linode Nanode in Chicago that
publishes the homelab Minecraft and Palworld servers without exposing the home
public IP address.

```text
Players
  |
  v
Linode 172.233.217.64
  |
  | nftables DNAT/SNAT
  v
Tailscale encrypted tunnel
  |
  v
pfSense subnet router (10.42.0.0/24)
  |
  +-- 10.42.0.12  Minecraft survival
  +-- 10.42.0.13  Minecraft creative
  +-- 10.42.0.14  Palworld
```

Terraform manages the Linode instance and its Cloud Firewall. Cloud-init
enables IPv4 forwarding, installs Tailscale, and installs the nftables rules
from [`nftables.conf`](nftables.conf). Tailscale authorization is completed
manually so no tailnet credentials are stored in Terraform state or Git.

## Prerequisites

- Terraform 1.6 or newer
- A Linode account and API token with read/write access to Linodes and
  firewalls
- An SSH key pair
- A pfSense Tailscale node advertising `10.42.0.0/24`
- Permission to approve devices and subnet routes in the Tailscale admin
  console

The optional `linode-cli` can be configured with:

```bash
linode-cli configure
linode-cli account view
```

## Files

| File | Purpose |
|---|---|
| `versions.tf` | Pins Terraform and the Linode provider |
| `variables.tf` | Declares the region, plan, image, SSH source, and key |
| `terraform.tfvars.example` | Safe example values for local configuration |
| `main.tf` | Creates the Linode and deny-by-default Cloud Firewall |
| `cloud-init.yaml.tftpl` | Bootstraps forwarding, Tailscale, and nftables |
| `nftables.conf` | Maps public game ports to the MetalLB addresses |
| `outputs.tf` | Prints the instance ID, public IP, and SSH command |

Terraform working directories, plans, state, and `terraform.tfvars` are
ignored by Git. Terraform state still contains infrastructure details and
should be stored or backed up securely.

## Configure credentials

Terraform reads the Linode API token from `LINODE_TOKEN`. To avoid placing the
token in shell history, read it interactively:

```bash
read -rsp "Linode API token: " LINODE_TOKEN
echo
export LINODE_TOKEN
```

An existing `linode-cli` profile can also supply the token. Replace
`noelmiller` if a different profile name is configured:

```bash
PROFILE=noelmiller
export LINODE_TOKEN="$(
  awk -v profile="[$PROFILE]" '
    $0 == profile { active=1; next }
    /^\[/ { active=0 }
    active && /^token[[:space:]]*=/ {
      sub(/^[^=]*=[[:space:]]*/, "")
      print
      exit
    }
  ' ~/.config/linode-cli
)"
```

Do not put the token in `terraform.tfvars`, commit it, or copy it to the
Linode.

## Configure variables

Create the local variables file:

```bash
cd 10-linode-relay
cp terraform.tfvars.example terraform.tfvars
```

Find the public address from which SSH administration will originate:

```bash
curl -4 https://ifconfig.me
```

Set that address as a `/32` in `terraform.tfvars`:

```hcl
region              = "us-ord"
instance_type       = "g6-nanode-1"
image               = "linode/ubuntu24.04"
admin_cidr          = "203.0.113.10/32"
ssh_public_key_path = "~/.ssh/id_ed25519.pub"
```

| Variable | Default | Description |
|---|---|---|
| `region` | `us-ord` | Chicago Linode region |
| `instance_type` | `g6-nanode-1` | 1 GiB Nanode plan |
| `image` | `linode/ubuntu24.04` | Relay operating system |
| `admin_cidr` | Required | Public IPv4 CIDR permitted to use SSH |
| `ssh_public_key_path` | `~/.ssh/id_ed25519.pub` | Root SSH public key |

The `admin_cidr` validation rejects `0.0.0.0/0`.

## Deploy

Initialize, review, and apply the stack:

```bash
terraform init
terraform validate
terraform plan -out=tfplan
terraform apply tfplan
```

Retrieve the connection details:

```bash
terraform output
terraform output -raw relay_public_ip
terraform output -raw ssh_command
```

Wait for the first-boot configuration to finish:

```bash
ssh root@$(terraform output -raw relay_public_ip) \
  'cloud-init status --wait'
```

## Connect Tailscale

On pfSense, configure the Tailscale package as a subnet router:

1. Authenticate pfSense to the intended tailnet.
2. Advertise `10.42.0.0/24`.
3. Approve the advertised subnet route in the Tailscale admin console.
4. Confirm pfSense remains authorized and does not have an expired node key.

Then authorize the Linode and accept the pfSense route:

```bash
ssh root@$(terraform output -raw relay_public_ip)
tailscale up --accept-routes --hostname=game-relay --ssh=false
```

Open the displayed URL and approve the `game-relay` device. For an unattended
server, consider disabling key expiry for this device in the Tailscale admin
console.

Verify that the route is installed and the peer is reachable:

```bash
tailscale status
ip route show table 52
tailscale ping <pfsense-tailscale-ip>
```

`tailscale ping` should eventually report a direct public endpoint. A DERP
connection still works but adds latency. The Linode Cloud Firewall permits
`41641/UDP` so Tailscale can establish a direct encrypted connection.

## Port forwarding

The Cloud Firewall uses a default-deny inbound policy and permits only:

| Port | Protocol | Purpose |
|---:|:---:|---|
| 22 | TCP | SSH from `admin_cidr` |
| 41641 | UDP | Tailscale direct connections |
| 25565 | TCP | Minecraft survival Java |
| 19132 | UDP | Minecraft survival Bedrock |
| 25566 | TCP | Minecraft creative Java |
| 19133 | UDP | Minecraft creative Bedrock |
| 8211 | UDP | Palworld gameplay |
| 27015 | UDP | Palworld community discovery |

The nftables rules translate those public ports as follows:

| Public port | Tailscale-routed destination |
|---:|---|
| `25565/TCP` | `10.42.0.12:25565` |
| `19132/UDP` | `10.42.0.12:19132` |
| `25566/TCP` | `10.42.0.13:25566` |
| `19133/UDP` | `10.42.0.13:19133` |
| `8211/UDP` | `10.42.0.14:8211` |
| `27015/UDP` | `10.42.0.14:27015` |

The relay masquerades forwarded traffic before sending it through Tailscale.
pfSense then SNATs subnet-routed traffic to its LAN address, which is permitted
by the Kubernetes `loadBalancerSourceRanges`.

An nftables output policy also prevents processes running on the Linode from
using the accepted subnet route to access arbitrary homelab services. Locally
originated traffic to `10.42.0.0/24` is accepted only for the destination and
port combinations in the forwarding table above; all other traffic to that
subnet is explicitly rejected.

Palworld's REST API on `8212/TCP`, Minecraft RCON, Kubernetes, and homelab
management services are not exposed.

## Verify the relay

From the Linode, confirm that the routed Minecraft targets are reachable:

```bash
nc -zvw5 10.42.0.12 25565
nc -zvw5 10.42.0.13 25566
```

From a network outside the homelab, verify the public Java ports:

```bash
nc -zvw5 172.233.217.64 25565
nc -zvw5 172.233.217.64 25566
```

Use Minecraft Bedrock and Palworld clients for protocol-level UDP testing.
Inspect nftables counters to confirm that packets reach each forwarding rule:

```bash
ssh root@172.233.217.64 'nft list table ip game_relay'
```

Palworld is configured to advertise `172.233.217.64:8211` in the community
browser. Both `8211/UDP` and `27015/UDP` must remain reachable. Community
browser results can take several minutes to update and may not show every
registered server in the initial result set.

## DNS

Create DNS-only records that point game hostnames to the
`relay_public_ip` output. Do not enable Cloudflare proxying: the standard
Cloudflare proxy and Cloudflare Tunnel do not proxy these arbitrary TCP and
UDP game protocols.

The Linode IPv4 address remains stable while the instance exists. Destroying
and recreating the instance can allocate a different address, requiring DNS
and Palworld's `PUBLIC_IP` setting to be updated.

## Operations

Check the relay services and routes:

```bash
ssh root@$(terraform output -raw relay_public_ip)
systemctl status tailscaled nftables
tailscale status
ip route show table 52
nft list table ip game_relay
```

Reapply nftables after editing `nftables.conf`:

```bash
scp nftables.conf root@$(terraform output -raw relay_public_ip):/tmp/game-relay.nft
ssh root@$(terraform output -raw relay_public_ip) '
  nft --check --file /tmp/game-relay.nft &&
  install -m 0644 /tmp/game-relay.nft /etc/nftables.conf &&
  systemctl restart nftables &&
  systemctl restart tailscaled &&
  tailscale set --accept-routes=true
'
```

Cloud-init user data is treated as create-time-only because changing Linode
metadata would replace the VM. Changes to `cloud-init.yaml.tftpl` or
`nftables.conf` therefore affect newly created instances automatically, but
must be applied manually to the existing relay.

A powered-off Linode continues to incur charges because its compute, disk, and
IPv4 resources remain reserved.

## Troubleshooting

| Symptom | Check |
|---|---|
| No `10.42.0.0/24` route | Approve the pfSense route and rerun `tailscale set --accept-routes=true` |
| Tailscale uses DERP only | Confirm `41641/UDP` is open and pfSense permits outbound UDP |
| Public TCP connects but the game does not respond | Confirm the destination pod and MetalLB service are ready |
| No packets in nftables counters | Check the Linode Cloud Firewall and public port |
| Packets leave `tailscale0` but do not reach Kubernetes | Check pfSense subnet routing, SNAT, and firewall rules |
| The relay cannot reach another homelab service | Expected: relay egress is restricted to the documented game destinations and ports |
| Palworld is absent from the browser | Confirm `-publiclobby`, `PUBLIC_IP`, both UDP ports, and allow time for registration |
| SSH stops working after an ISP address change | Update `admin_cidr` and run `terraform apply` from an authorized connection |

## Destroy

The instance has `prevent_destroy = true` to avoid accidentally deleting its
public IP and Tailscale identity. To intentionally remove the relay:

1. Set `prevent_destroy = false` in `main.tf`.
2. Run `terraform plan -destroy` and review every resource.
3. Run `terraform destroy`.
4. Remove the old `game-relay` device from the Tailscale admin console.
5. Remove or update DNS records that referenced the released public IP.
