datacenter = "dc1"
data_dir   = "/opt/consul"
log_level  = "INFO"
node_name  = "__NODE_NAME__"

server = false

# The worker has no L3 path to the control-plane LAN — it only sees the
# servers via tailnet, so all gossip/advertise has to happen on the
# Tailscale interface.
bind_addr      = "__TAILSCALE_IP__"
advertise_addr = "__TAILSCALE_IP__"
client_addr    = "0.0.0.0"

retry_join = [__SERVER_TS_HOSTS_LIST__]

connect {
  enabled = true
}

ports {
  grpc = 8502
}

acl {
  enabled = false
}
