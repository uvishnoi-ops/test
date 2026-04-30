# vagrant-vault-consul-nomad-lab

A Vagrant + libvirt lab that brings up a 3-node HashiCorp control plane
(Vault, Consul, Nomad — all in server mode on every node) plus one Nomad
workload-runner node on a separate virtual network. Cross-network traffic
between the worker and the control plane is forced over Tailscale; there is
no L3 path between the two libvirt networks.

> **Lab scope only.** TLS is disabled, Consul ACLs are disabled, the Nomad
> ACL system is not bootstrapped, and Vault unseal keys are written to a
> Vagrant-shared folder. Do not reuse this configuration in production.

## Topology

```
                         tailnet (100.64.0.0/10, MagicDNS)
   ┌──────────────────────────────────────────────────────────────┐
   │                                                              │
┌──┴──────────┐  ┌─────────────┐  ┌─────────────┐         ┌───────┴──────┐
│  server1    │  │  server2    │  │  server3    │         │   worker1    │
│  vault srv  │  │  vault srv  │  │  vault srv  │         │ nomad client │
│  consul srv │  │  consul srv │  │  consul srv │         │ consul client│
│  nomad srv  │  │  nomad srv  │  │  nomad srv  │         │              │
└─────┬───────┘  └─────┬───────┘  └─────┬───────┘         └───────┬──────┘
      │                │                │                         │
   eth1│ 192.168.56.11 │ .12          │ .13                       │ eth1
      │                │                │              192.168.57.21
      └────────┬───────┴────────────────┘                         │
            lab-mgmt (libvirt isolated, no NAT)              lab-workload
                                                       (libvirt isolated, no NAT)
```

Server-to-server replication (Vault Raft, Consul gossip, Nomad Raft/Serf)
runs on `lab-mgmt` (eth1, `192.168.56.0/24`). The worker is on
`lab-workload` (`192.168.57.0/24`) which is a different libvirt network;
the kernel has no route between them. The only path the worker has to
reach the servers is via the Tailscale interface.

## Resource usage

| Node     | CPU | RAM   | Disk  |
| -------- | --- | ----- | ----- |
| server1  | 3   | 4 GiB | 20 GB |
| server2  | 3   | 4 GiB | 20 GB |
| server3  | 3   | 4 GiB | 20 GB |
| worker1  | 3   | 4 GiB | 20 GB |
| **total**| 12  | 16 GiB| 80 GB |

## Prerequisites

- Linux host with KVM/QEMU + libvirt (`virsh list` works)
- Vagrant ≥ 2.3
- `vagrant plugin install vagrant-libvirt`
- A Tailscale tailnet and a reusable, ephemeral auth key
- ~16 GiB free RAM and ~80 GB free disk

## Running

```bash
export TS_AUTHKEY=tskey-auth-...         # ephemeral, reusable
vagrant up --provider=libvirt
```

Bring-up is **sequential by design** — Vagrant will not start `server2`
until `server1` finishes provisioning, and the worker only starts after
all three servers are up. Expect ~15–25 minutes on a fresh host.

## Provisioning order (per server)

1. `common.sh` — base packages, kernel sysctls
2. `tailscale.sh` — install + `tailscale up --authkey=… --hostname=…`
3. `vault_install.sh` — install Vault, render config with raft `retry_join`
   pointing at `server1`, start `vault.service`
4. On `server1`: `vault_init_unseal.sh` — `operator init`, save unseal
   keys to `/vagrant/.vault-keys/init.json`, unseal
5. On `server1`: `vault_seed.sh` — wait for Vault leader, mount KV v2,
   write the test secret, write the `nomad-server` and `nomad-job`
   policies, write the `nomad-cluster` token role, mint a periodic token
   for Nomad and save it to `/vagrant/.vault-keys/nomad-token`
6. On `server2`/`server3`: `vault_unseal.sh` — read keys from the shared
   folder and unseal (raft auto-join already happened via `retry_join`)
7. `consul_server.sh` — install Consul, `bootstrap_expect=3`, start
8. `nomad_server.sh` — install Nomad with the Vault token from step 5,
   `bootstrap_expect=3`, start

For the worker:
1. `common.sh` + `tailscale.sh`
2. `consul_client.sh` — Consul agent in client mode, `retry_join` over
   tailnet hostnames (`vcn-server-1`, …)
3. `nomad_client.sh` — Nomad client, `servers = [<tailnet hostnames>]`
4. `run_tests.sh` — verification suite (see below)

## Verification

`scripts/run_tests.sh` runs at the end of the worker provisioner and
prints a green/red summary for each check:

- All three Vault nodes reachable over the tailnet, raft has 3 voters
- Consul has 3 servers, leader-elected, worker shows up as a client
- Nomad has 3 servers, leader-elected, worker registered as a client
  with status `ready`
- The `hello` job reaches `running` and renders the Vault secret into
  `local/secrets.env` (proves end-to-end Vault auth from a task)
- `hello.test-service` is registered in Consul and its check is passing

You can re-run the suite at any time:

```bash
vagrant ssh worker1 -c "sudo /vagrant/scripts/run_tests.sh"
```

## Useful endpoints

After `vagrant up`, on the host:

```bash
# Vault root token + unseal keys
cat .vault-keys/init.json | jq

# Nomad UI (over tailnet hostname)
xdg-open "http://vcn-server-1:4646"

# Consul UI
xdg-open "http://vcn-server-1:8500"
```

Or from inside any VM (`vagrant ssh server1`):

```bash
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=$(jq -r .root_token /vagrant/.vault-keys/init.json)
vault status
vault operator raft list-peers

consul members
nomad server members
nomad node status
```

## Tearing down

```bash
vagrant destroy -f
rm -rf .vault-keys
```

## File layout

```
Vagrantfile
scripts/
  common.sh                base packages
  tailscale.sh             install + auth
  vault_install.sh         binary, config, systemd start
  vault_init_unseal.sh     leader: operator init + first-time unseal
  vault_unseal.sh          followers: unseal using shared keys
  vault_seed.sh            KV/policies/token-role/periodic token
  consul_server.sh         server-mode agent
  consul_client.sh         client-mode agent (worker)
  nomad_server.sh          server-mode agent (with vault stanza)
  nomad_client.sh          client-mode agent (with vault stanza)
  run_tests.sh             worker-side verification suite
config/
  vault.hcl.tpl
  consul-server.hcl.tpl
  consul-client.hcl.tpl
  nomad-server.hcl.tpl
  nomad-client.hcl.tpl
jobs/
  hello.nomad.hcl          test job: vault template + consul service
```

## Known caveats

- **Unseal keys are on the host filesystem.** Anyone with read access to
  `.vault-keys/` can unseal Vault and read the root token. Acceptable for
  a throwaway lab, never for production.
- **No TLS.** All Vault/Consul/Nomad listeners are plaintext.
- **Single point for raft join.** `retry_join` points at `server1`; if
  `server1` is permanently lost before the cluster forms, `server2` and
  `server3` cannot bootstrap.
- **Tailscale dependency at provision time.** If your tailnet ACLs block
  any of the four hostnames, provisioning will hang on retry_join over
  the tailnet (worker side).
