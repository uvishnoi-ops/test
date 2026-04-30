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
RAFT_LEADER_IP    = SERVERS.first[:ip]

Vagrant.configure("2") do |config|
  config.vm.box = BOX

  # rsync project into each VM at /vagrant. Excludes the runtime keys dir so
  # generated unseal material is not synced from the host into the guest;
  # instead, the leader writes into /vagrant/.vault-keys which the rsync
  # back-channel surfaces to the host on each `vagrant rsync-back`.
  config.vm.synced_folder ".", "/vagrant",
    type: "rsync",
    rsync__exclude: [".git/", ".vagrant/"],
    rsync__args: ["--verbose", "--archive", "--delete", "-z"]

  config.vm.provider :libvirt do |lv|
    lv.cpus   = CPUS
    lv.memory = MEMORY
    lv.machine_virtual_size = 20
    lv.qemu_use_session = false
  end

  SERVERS.each_with_index do |srv, idx|
    is_leader = (idx == 0)
    is_last   = (idx == SERVERS.length - 1)

    config.vm.define srv[:name] do |node|
      node.vm.hostname = srv[:name]

      # eth1: control-plane LAN (isolated, no forward).
      node.vm.network :private_network,
        ip: srv[:ip],
        libvirt__network_name: MGMT_NETWORK,
        libvirt__forward_mode: "none",
        libvirt__dhcp_enabled: false

      common_env = {
        "NODE_NAME"         => srv[:name],
        "NODE_LAN_IP"       => srv[:ip],
        "NODE_TS_HOSTNAME"  => srv[:ts_hostname],
        "RAFT_LEADER_IP"    => RAFT_LEADER_IP,
        "SERVER_LAN_IPS"    => SERVER_LAN_IPS,
        "SERVER_TS_HOSTS"   => SERVER_TS_HOSTS,
        "IS_RAFT_LEADER"    => is_leader.to_s,
      }

      node.vm.provision "common", type: "shell",
        path: "scripts/common.sh"

      node.vm.provision "tailscale", type: "shell",
        path: "scripts/tailscale.sh",
        env: { "TS_AUTHKEY" => TS_AUTHKEY,
               "TS_HOSTNAME" => srv[:ts_hostname] }

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
        node.vm.provision "vault-unseal", type: "shell",
          path: "scripts/vault_unseal.sh",
          env: common_env
      end

      node.vm.provision "consul-server", type: "shell",
        path: "scripts/consul_server.sh",
        env: common_env

      node.vm.provision "nomad-server", type: "shell",
        path: "scripts/nomad_server.sh",
        env: common_env
    end
  end

  WORKERS.each do |w|
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
        env: { "TS_AUTHKEY" => TS_AUTHKEY,
               "TS_HOSTNAME" => w[:ts_hostname] }

      node.vm.provision "consul-client", type: "shell",
        path: "scripts/consul_client.sh",
        env: common_env

      node.vm.provision "nomad-client", type: "shell",
        path: "scripts/nomad_client.sh",
        env: common_env

      node.vm.provision "run-tests", type: "shell",
        path: "scripts/run_tests.sh",
        env: common_env
    end
  end
end
