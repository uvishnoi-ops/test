datacenter = "dc1"
data_dir   = "/opt/consul"
log_level  = "INFO"
node_name  = "__NODE_NAME__"

server           = true
bootstrap_expect = 3

# Gossip + RPC bind on the control-plane LAN. HTTP API on all interfaces
# (so the local nomad-server can reach 127.0.0.1:8500 and operators can
# hit the UI over the tailnet).
bind_addr      = "__NODE_LAN_IP__"
advertise_addr = "__NODE_LAN_IP__"
client_addr    = "0.0.0.0"

# Tailnet hostname is added as a second advertise so the worker can
# reach this server's API + DNS over Tailscale.
advertise_addr_wan = "__NODE_TS_IP__"

retry_join = [__SERVER_LAN_IPS_LIST__]

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
