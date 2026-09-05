variable "region" {
  description = "Linode region in which to deploy the relay."
  type        = string
  default     = "us-ord"
}

variable "instance_type" {
  description = "Linode plan used by the relay."
  type        = string
  default     = "g6-nanode-1"
}

variable "image" {
  description = "Linux image used by the relay."
  type        = string
  default     = "linode/ubuntu24.04"
}

variable "admin_cidr" {
  description = "Public IPv4 CIDR allowed to SSH to the relay, normally your current public IP with /32."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.admin_cidr)) && var.admin_cidr != "0.0.0.0/0"
    error_message = "admin_cidr must be a valid IPv4 CIDR and must not allow the entire internet."
  }
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key installed for the root user."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}
