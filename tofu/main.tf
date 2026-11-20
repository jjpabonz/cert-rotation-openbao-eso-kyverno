terraform {
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "5.9.0"
    }
  }
}

provider "vault" {
  address         = "http://openbao.kube1.example.com" # same address as BAO_ADDR in docs/00-setup.md
  token           = "<initial root token>"           # do not commit a real token
  #  skip_tls_verify = true
}

# 1. Enable Kubernetes Auth Method
resource "vault_auth_backend" "kubernetes" {
  type = "kubernetes"
}

resource "vault_auth_backend" "kubernetes_remote" {
  type = "kubernetes"
  path = "k8s-remote"
}
# 2. Configure Kubernetes Auth Method
resource "vault_kubernetes_auth_backend_config" "config" {
  backend         = vault_auth_backend.kubernetes.path
  kubernetes_host = "https://kubernetes.default.svc"
}

resource "vault_kubernetes_auth_backend_config" "config_remote" {
  backend            = vault_auth_backend.kubernetes_remote.path
  kubernetes_host    = "https://kube2.example.com:6443"
  kubernetes_ca_cert = file("kube2-ca.crt")
  disable_local_ca_jwt = true
}

# 3. Create the KV version 2 secret engine 'certificates'
resource "vault_mount" "kvv2" {
  path        = "certificates"
  type        = "kv-v2"
  description = "KV Version 2 secret engine"
}

# 4. Create Policy for Read/Write Access
resource "vault_policy" "external-secrets-policy" {
  name   = "external-secrets-policy"
  policy = <<EOT
path "certificates/data/*" {
  capabilities = ["read", "list"]
}
EOT
}

# 5. Create Kubernetes Auth Role
resource "vault_kubernetes_auth_backend_role" "external-secrets-role" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "external-secrets-role"
  bound_service_account_names      = ["external-secrets"]
  bound_service_account_namespaces = ["external-secrets"]
  token_policies                   = [vault_policy.external-secrets-policy.name]
  token_ttl                        = 3600
}

resource "vault_kubernetes_auth_backend_role" "external-secrets-role-remote" {
  backend                          = vault_auth_backend.kubernetes_remote.path
  role_name                        = "external-secrets-role"
  bound_service_account_names      = ["external-secrets"]
  bound_service_account_namespaces = ["external-secrets"]
  token_policies                   = [vault_policy.external-secrets-policy.name]
  token_ttl                        = 600
  token_max_ttl                    = 1800
}
