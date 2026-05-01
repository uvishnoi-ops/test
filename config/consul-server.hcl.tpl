datacenter = "dc1"
data_dir   = "/opt/consul"
log_level  = "INFO"
node_name  = "__NODE_NAME__"

server           = true
bootstrap_expect = 3

# Bind all ports on all interfaces so the worker can reach 8301 (serf LAN
# gossip) via the Tailscale interface. advertise_addr keeps server-to-server
# gossip on the control-plane LAN; client_addr exposes the HTTP API
# everywhere so the local nomad-server and operators on the tailnet can
# reach it.
bind_addr      = "0.0.0.0"
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
