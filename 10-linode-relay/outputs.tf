output "instance_id" {
  description = "ID of the Linode relay instance."
  value       = linode_instance.relay.id
}

output "relay_public_ip" {
  description = "Public IPv4 address used for game DNS and Palworld publication."
  value       = tolist(linode_instance.relay.ipv4)[0]
}

output "ssh_command" {
  description = "Command used to connect to the relay from the permitted admin CIDR."
  value       = "ssh root@${tolist(linode_instance.relay.ipv4)[0]}"
}
