ui            = true
disable_mlock = true

storage "raft" {
  path    = "/opt/vault/data"
  node_id = "__NODE_NAME__"

  retry_join {
    leader_api_addr = "http://__RAFT_LEADER_IP__:8200"
  }
}

listener "tcp" {
  address         = "0.0.0.0:8200"
  cluster_address = "__NODE_LAN_IP__:8201"
  tls_disable     = true
}

# api_addr is what other Vault nodes use to forward requests to this node.
# cluster_addr is what other Vault nodes use to talk raft + clustering RPC.
# Both must be reachable on the control-plane LAN.
api_addr     = "http://__NODE_LAN_IP__:8200"
cluster_addr = "http://__NODE_LAN_IP__:8201"
