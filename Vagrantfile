# -*- mode: ruby -*-
# vi: set ft=ruby :
#
# Vagrant + libvirt lab: 3-node Vault/Consul/Nomad control plane + 1 Nomad
# workload runner on a separate virtual network. Cross-network communication
# happens via Tailscale.
#
# Usage:
#   vagrant plugin install vagrant-libvirt
#   export TS_AUTHKEY=tskey-auth-...   # ephemeral, reusable Tailscale auth key
#   vagrant up --provider=libvirt
#
# Bring-up order is sequential by design:
#   server1 (Vault leader -> init/unseal/seed) -> server2 -> server3 -> worker1
#
# All paths are POSIX; this Vagrantfile is intended to run on a Linux host
# with libvirt/QEMU/KVM. It will not work on Windows directly.

REQUIRED_PLUGINS = %w[vagrant-libvirt]
REQUIRED_PLUGINS.each do |p|
  unless Vagrant.has_plugin?(p)
    raise "Missing Vagrant plugin '#{p}'. Install with: vagrant plugin install #{p}"
  end
end

TS_AUTHKEY = ENV["TS_AUTHKEY"].to_s
if TS_AUTHKEY.empty?
  raise "TS_AUTHKEY env var is not set. Generate a reusable, ephemeral auth key " \
        "at https://login.tailscale.com/admin/settings/keys and re-run with " \
        "TS_AUTHKEY=tskey-... vagrant up"
end

BOX     = "generic/ubuntu2204"
CPUS    = 3
MEMORY  = 4096

# Control-plane LAN (libvirt isolated private network, no NAT to host).
MGMT_NETWORK = "lab-mgmt"

# Workload-runner network (a different libvirt isolated network so there is
# no L3 path between the worker and the control-plane LAN; the only way
# the worker can reach the servers is over the Tailscale tailnet).
WORKLOAD_NETWORK = "lab-workload"

SERVERS = [
  { name: "server1", ip: "192.168.56.11", ts_hostname: "vcn-server-1" },
  { name: "server2", ip: "192.168.56.12", ts_hostname: "vcn-server-2" },
  { name: "server3", ip: "192.168.56.13", ts_hostname: "vcn-server-3" },
]

WORKERS = [
  { name: "worker1", ip: "192.168.57.21", ts_hostname: "vcn-worker-1" },
]

SERVER_LAN_IPS    = SERVERS.map { |s| s[:ip] }.join(",")
SERVER_TS_HOSTS   = SERVERS.map { |s| s[:ts_hostname] }.join(",")
SERVER_NAMES      = SERVERS.map { |s| s[:name] }.join(",")
RAFT_LEADER_IP    = SERVERS.first[:ip]

Vagrant.configure("2") do |config|
  config.vm.box = BOX

  # NFS shared folder so all VMs see the same /vagrant in real time.
  # This is required for the key-sharing flow: server1 writes
  # .vault-keys/init.json and .vault-keys/nomad-token during provisioning,
  # and server2/server3 poll for those files before they can unseal and
  # start Nomad. With rsync (one-way host->guest copy) those writes never
  # reach the other VMs. NFS is a true shared mount backed by the host.
  # Host prerequisite: sudo apt-get install nfs-kernel-server
  config.vm.synced_folder ".", "/vagrant",
    type: "nfs",
    nfs_udp: false,
    nfs_version: 4

  # Remove the phase-barrier marker directory from the host after any machine
  # is destroyed. .done/ lives on the host (it is inside the NFS-shared
  # /vagrant), so stale markers from a previous run would cause wait_done
  # calls on the next `vagrant up` to return immediately and skip the
  # intended ordering. Triggering on each destroy is safe because rm -rf
  # is idempotent.
  config.trigger.after :destroy do |t|
    t.name = "clean up .done barrier dir"
    t.run  = { inline: "rm -rf .done" }
  end

  config.vm.provider :libvirt do |lv|
    lv.cpus   = CPUS
    lv.memory = MEMORY
    lv.machine_virtual_size = 20
    lv.qemu_use_session = false
  end

  SERVERS.each_with_index do |srv, idx|
    is_leader = (idx == 0)
    is_last   = (idx == SERVERS.length - 1)

    # Phase barriers: each server only waits for nodes provisioned before it
    # (sequential bring-up means later nodes don't exist yet).
    vault_barrier  = SERVERS[0..idx].map { |s| s[:name] }.join(",")
    consul_barrier = SERVERS[0..idx].map { |s| s[:name] }.join(",")

    config.vm.define srv[:name] do |node|
      node.vm.hostname = srv[:name]

      # eth1: control-plane LAN (isolated, no forward).
      node.vm.network :private_network,
        ip: srv[:ip],
        libvirt__network_name: MGMT_NETWORK,
        libvirt__forward_mode: "none",
        libvirt__dhcp_enabled: false

      common_env = {
        "NODE_NAME"               => srv[:name],
        "NODE_LAN_IP"             => srv[:ip],
        "NODE_TS_HOSTNAME"        => srv[:ts_hostname],
        "RAFT_LEADER_IP"          => RAFT_LEADER_IP,
        "RAFT_LEADER_TS_HOSTNAME" => SERVERS.first[:ts_hostname],
        "SERVER_LAN_IPS"          => SERVER_LAN_IPS,
        "SERVER_TS_HOSTS"         => SERVER_TS_HOSTS,
        "IS_RAFT_LEADER"          => is_leader.to_s,
      }

      node.vm.provision "common", type: "shell",
        path: "scripts/common.sh"

      node.vm.provision "tailscale", type: "shell",
        path: "scripts/tailscale.sh",
        env: { "TS_AUTHKEY"  => TS_AUTHKEY,
               "TS_HOSTNAME" => srv[:ts_hostname],
               "NODE_NAME"   => srv[:name] }

      node.vm.provision "vault-install", type: "shell",
        path: "scripts/vault_install.sh",
        env: common_env

      if is_leader
        node.vm.provision "vault-init", type: "shell",
          path: "scripts/vault_init_unseal.sh",
          env: common_env
        # Seeding (KV, policies, periodic Nomad token) must happen before
        # nomad_server.sh on this node, because nomad_server.sh reads the
        # token from /vagrant/.vault-keys/nomad-token.
        node.vm.provision "vault-seed", type: "shell",
          path: "scripts/vault_seed.sh",
          env: common_env
      else
        # Followers must wait for every server provisioned before them to
        # finish their full vault phase (init+seed on server1, unseal on
        # any intermediate follower) before attempting raft-join + unseal.
        prior_vault_nodes = SERVERS[0...idx].map { |s| s[:name] }.join(",")
        node.vm.provision "vault-unseal", type: "shell",
          path: "scripts/vault_unseal.sh",
          env: common_env.merge("VAULT_UNSEAL_BARRIER_NODES" => prior_vault_nodes)
      end

      node.vm.provision "consul-server", type: "shell",
        path: "scripts/consul_server.sh",
        env: common_env.merge("VAULT_BARRIER_NODES" => vault_barrier)

      node.vm.provision "nomad-server", type: "shell",
        path: "scripts/nomad_server.sh",
        env: common_env.merge("CONSUL_BARRIER_NODES" => consul_barrier)
    end
  end

  WORKERS.each do |w|
    # Worker comes after all servers, so it can wait for all of them.
    vault_barrier  = SERVER_NAMES
    consul_barrier = "#{SERVER_NAMES},#{w[:name]}"

    config.vm.define w[:name] do |node|
      node.vm.hostname = w[:name]

      # eth1: workload network (isolated, separate from MGMT_NETWORK -> the
      # worker has no L3 route to control-plane LAN IPs).
      node.vm.network :private_network,
        ip: w[:ip],
        libvirt__network_name: WORKLOAD_NETWORK,
        libvirt__forward_mode: "none",
        libvirt__dhcp_enabled: false

      common_env = {
        "NODE_NAME"        => w[:name],
        "NODE_TS_HOSTNAME" => w[:ts_hostname],
        "SERVER_TS_HOSTS"  => SERVER_TS_HOSTS,
      }

      node.vm.provision "common", type: "shell",
        path: "scripts/common.sh"

      node.vm.provision "tailscale", type: "shell",
        path: "scripts/tailscale.sh",
        env: { "TS_AUTHKEY"  => TS_AUTHKEY,
               "TS_HOSTNAME" => w[:ts_hostname],
               "NODE_NAME"   => w[:name] }

      node.vm.provision "consul-client", type: "shell",
        path: "scripts/consul_client.sh",
        env: common_env.merge("VAULT_BARRIER_NODES" => vault_barrier)

      node.vm.provision "nomad-client", type: "shell",
        path: "scripts/nomad_client.sh",
        env: common_env.merge("CONSUL_BARRIER_NODES" => consul_barrier)

      node.vm.provision "run-tests", type: "shell",
        path: "scripts/run_tests.sh",
        env: common_env
    end
  end
end
