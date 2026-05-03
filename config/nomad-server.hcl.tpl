datacenter = "dc1"
data_dir   = "/opt/nomad/data"
log_level  = "INFO"
name       = "__NODE_NAME__"

bind_addr = "0.0.0.0"

# Advertise on the Tailscale IP so all server-to-server and
# server-to-client traffic goes via the tailnet.
advertise {
  http = "__NODE_TS_IP__"
  rpc  = "__NODE_TS_IP__"
  serf = "__NODE_TS_IP__"
}

server {
  enabled          = true
  bootstrap_expect = 3

  server_join {
    retry_join = [__SERVER_TS_HOSTS_LIST__]
  }
}

# Servers don't run jobs in this lab.
client {
  enabled = false
}

consul {
  address = "127.0.0.1:8500"
  # Auto-advertise nomad servers + clients in Consul so the API can be
  # discovered as `nomad.service.consul`.
  auto_advertise      = true
  server_auto_join    = true
  client_auto_join    = true
}

vault {
  enabled          = true
  address          = "http://127.0.0.1:8200"
  create_from_role = "nomad-cluster"
  token            = "__NOMAD_VAULT_TOKEN__"
}

# Disable Nomad ACLs in this lab. Tailnet ACLs are the access boundary.
acl {
  enabled = false
}

telemetry {
  publish_allocation_metrics = true
  publish_node_metrics       = true
}
