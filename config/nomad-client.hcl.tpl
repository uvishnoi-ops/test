datacenter = "dc1"
data_dir   = "/opt/nomad/data"
log_level  = "INFO"
name       = "__NODE_NAME__"

bind_addr = "0.0.0.0"

# Worker only reaches the control plane via the tailnet.
advertise {
  http = "__TAILSCALE_IP__"
  rpc  = "__TAILSCALE_IP__"
  serf = "__TAILSCALE_IP__"
}

server {
  enabled = false
}

client {
  enabled = true
  servers = [__SERVER_TS_HOSTS_LIST__]

  # Lets the test job land somewhere even with no fancy constraints.
  meta {
    role = "workload"
  }
}

consul {
  # Local consul agent (also a client over tailnet).
  address          = "127.0.0.1:8500"
  auto_advertise   = true
  client_auto_join = true
}

vault {
  enabled = true
  # Tasks rendering templates need to talk to a real Vault. Hit the
  # leader (or any active node) over the tailnet.
  address          = "http://__VAULT_TS_HOST__:8200"
  create_from_role = "nomad-cluster"
  token            = "__NOMAD_VAULT_TOKEN__"
}

plugin "raw_exec" {
  config {
    enabled = true
  }
}

acl {
  enabled = false
}
