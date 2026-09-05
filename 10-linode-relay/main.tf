locals {
  tcp_ingress = {
    ssh = {
      description = "SSH administration"
      source      = var.admin_cidr
      ports       = "22"
    }
    minecraft-survival-java = {
      description = "Minecraft survival Java"
      source      = "0.0.0.0/0"
      ports       = "25565"
    }
    minecraft-creative-java = {
      description = "Minecraft creative Java"
      source      = "0.0.0.0/0"
      ports       = "25566"
    }
  }

  udp_ingress = {
    tailscale = {
      description = "Tailscale direct connection"
      source      = "0.0.0.0/0"
      ports       = "41641"
    }
    minecraft-survival-bedrock = {
      description = "Minecraft survival Bedrock"
      source      = "0.0.0.0/0"
      ports       = "19132"
    }
    minecraft-creative-bedrock = {
      description = "Minecraft creative Bedrock"
      source      = "0.0.0.0/0"
      ports       = "19133"
    }
    palworld-game = {
      description = "Palworld gameplay"
      source      = "0.0.0.0/0"
      ports       = "8211"
    }
    palworld-query = {
      description = "Palworld community server discovery"
      source      = "0.0.0.0/0"
      ports       = "27015"
    }
  }
}

resource "linode_instance" "relay" {
  label           = "game-relay"
  image           = var.image
  region          = var.region
  type            = var.instance_type
  authorized_keys = [trimspace(file(pathexpand(var.ssh_public_key_path)))]
  tags            = ["game-relay", "terraform"]
  swap_size       = 512

  metadata {
    user_data = base64encode(templatefile("${path.module}/cloud-init.yaml.tftpl", {
      hostname        = "game-relay"
      nftables_config = file("${path.module}/nftables.conf")
    }))
  }

  lifecycle {
    prevent_destroy = true
    ignore_changes  = [metadata[0].user_data]
  }
}

resource "linode_firewall" "relay" {
  label           = "game-relay"
  inbound_policy  = "DROP"
  outbound_policy = "ACCEPT"
  linodes         = [linode_instance.relay.id]
  tags            = ["game-relay", "terraform"]

  dynamic "inbound" {
    for_each = local.tcp_ingress

    content {
      label    = inbound.key
      action   = "ACCEPT"
      protocol = "TCP"
      ports    = inbound.value.ports
      ipv4     = [inbound.value.source]
    }
  }

  dynamic "inbound" {
    for_each = local.udp_ingress

    content {
      label    = inbound.key
      action   = "ACCEPT"
      protocol = "UDP"
      ports    = inbound.value.ports
      ipv4     = [inbound.value.source]
    }
  }

  inbound {
    label    = "icmp"
    action   = "ACCEPT"
    protocol = "ICMP"
    ipv4     = ["0.0.0.0/0"]
  }
}
