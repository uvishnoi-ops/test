datacenter = "dc1"
data_dir   = "/opt/consul"
log_level  = "INFO"
node_name  = "__NODE_NAME__"

server           = true
bootstrap_expect = 3

# All inter-node traffic (gossip, RPC) uses the Tailscale IP.
# Tailscale uses direct peer-to-peer when nodes are on the same LAN,
# so there is no relay penalty. client_addr stays 0.0.0.0 so the HTTP
# API is reachable on localhost by co-located services (Nomad, operators).
bind_addr      = "__NODE_TS_IP__"
advertise_addr = "__NODE_TS_IP__"
client_addr    = "0.0.0.0"

retry_join = [__SERVER_TS_HOSTS_LIST__]

ui_config {
  enabled = true
}

connect {
  enabled = true
}

ports {
  grpc = 8502
}

acl {
  enabled = false
}
