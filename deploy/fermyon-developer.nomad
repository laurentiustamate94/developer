variable "region" {
  type    = string
}

variable "production" {
  type        = bool
  default     = false
  description = "Whether or not this job should run in production mode. Default: false."
}

variable "dns_domain" {
  type        = string
  default     = "fermyon.com"
  description = "The root DNS domain for the Fermyon Developer docs website"
}

variable "hostname" {
  type        = string
  default     = null
  description = "An alternative hostname to use (defaults are <canary>.developer.<dns_domain>})"
}

variable "letsencrypt_env" {
  type    = string
  default = "prod"
  description = <<EOF
The Let's Encrypt cert resolver to use. Options are 'staging' and 'prod'. (Default: prod)

With the letsencrypt-prod cert resolver, we're limited to *5 requests per week* for a cert with matching domain and SANs.
For testing/staging, it is recommended to use letsencrypt-staging, which has vastly increased limits.
EOF

  validation {
    condition     = var.letsencrypt_env == "staging" || var.letsencrypt_env == "prod"
    error_message = "The Let's Encrypt env must be either 'staging' or 'prod'."
  }
}

variable "oci_ref" {
  type        = string
  default     = "fermyon/developer:latest"
  description = "The OCI reference of the Spin app for the Fermyon Developer website"
}

variable "commit_sha" {
  type        = string
  default     = ""
  description = "The git commit sha that the website is published from"
}

locals {
  hostname = "${var.hostname == null ? "${var.production == true ? "developer.${var.dns_domain}" : "canary.developer.${var.dns_domain}"}" : var.hostname}"
}

job "fermyon-developer" {
  type = "service"
  datacenters = [
    "${var.region}a",
    "${var.region}b",
    "${var.region}c",
    "${var.region}d",
    "${var.region}e",
    "${var.region}f"
  ]

  # Add unique metadata to support recreating the job even if var.oci_ref
  # represents a mutable tag (eg latest).
  meta {
    commit_sha = var.commit_sha
  }

  group "fermyon-developer" {
    count = 3

    update {
      max_parallel      = 1
      canary            = 3
      min_healthy_time  = "10s"
      healthy_deadline  = "10m"
      progress_deadline = "15m"
      auto_revert       = true
      auto_promote      = true
    }

    network {
      port "http" {}
    }

    service {
      name = "fermyon-developer-${NOMAD_NAMESPACE}"
      port = "http"

      tags = [
        "traefik.enable=true",
        "traefik.http.routers.fermyon-developer-${NOMAD_NAMESPACE}.rule=Host(`${local.hostname}`)",
        "traefik.http.routers.fermyon-developer-${NOMAD_NAMESPACE}.entryPoints=websecure",
        "traefik.http.routers.fermyon-developer-${NOMAD_NAMESPACE}.tls=true",
        "traefik.http.routers.fermyon-developer-${NOMAD_NAMESPACE}.tls.certresolver=letsencrypt-${var.letsencrypt_env}",
        "traefik.http.routers.fermyon-developer-${NOMAD_NAMESPACE}.tls.domains[0].main=${local.hostname}"
      ]

      check {
        type     = "http"
        path     = "/.well-known/spin/health"
        interval = "10s"
        timeout  = "2s"
      }
    }

    task "server" {
      driver = "exec"

      artifact {
        source = "https://github.com/fermyon/spin/releases/download/v1.1.0/spin-v1.1.0-linux-amd64.tar.gz"
        options {
          checksum = "sha256:13ecd7be7fb3a054f41b72d65fd6648cd8221e5df57c6694f1a8e5532b79040d"
        }
      }

      env {
        RUST_LOG   = "spin=trace"
        BASE_URL   = "https://${local.hostname}"
      }

      config {
        command = "spin"
        args = [
          "up",
          "--from", var.oci_ref,
          "--listen", "${NOMAD_IP_http}:${NOMAD_PORT_http}",
          "--log-dir", "${NOMAD_ALLOC_DIR}/logs",
          "--temp", "${NOMAD_ALLOC_DIR}/tmp",

          # Set BASE_URL for Bartholomew to override default (localhost:3000)
          "-e", "BASE_URL=${BASE_URL}",
        ]
      }
    }
  }
}
