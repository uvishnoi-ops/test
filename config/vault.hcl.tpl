ui            = true
disable_mlock = true

storage "raft" {
  path    = "/opt/vault/data"
  node_id = "__NODE_NAME__"

  retry_join {
    leader_api_addr = "http://__RAFT_LEADER_TS_HOSTNAME__:8200"
  }
}

listener "tcp" {
  address         = "0.0.0.0:8200"
  cluster_address = "__NODE_TS_IP__:8201"
  tls_disable     = true
}

# api_addr  — address other Vault nodes use to forward requests here.
# cluster_addr — address used for Raft + clustering RPC between nodes.
# Both use the Tailscale IP so all inter-node traffic goes via the tailnet
# (Tailscale will use direct peer-to-peer when nodes are co-located).
api_addr     = "http://__NODE_TS_IP__:8200"
cluster_addr = "http://__NODE_TS_IP__:8201"
