job "hello" {
  datacenters = ["dc1"]
  type        = "service"

  group "hello" {
    count = 1

    network {
      port "http" {
        to = 8080
      }
    }

    # Workload Identity: Nomad signs a JWT for this task (vault_default
    # identity defined on the server). The Nomad client exchanges the JWT
    # at Vault's jwt/ auth backend. The nomad-cluster role maps that JWT
    # to the nomad-job policy which has read access to kv/test/*.
    vault {
      change_mode = "noop"
    }

    service {
      name = "hello"
      port = "http"
      tags = ["test", "vcn-lab", "nginx"]

      # Use the dedicated /health endpoint so Consul checks don't generate
      # noise in the access log (access_log off inside that location block).
      check {
        type     = "http"
        path     = "/health"
        interval = "10s"
        timeout  = "2s"
      }
    }

    task "hello" {
      driver = "raw_exec"

      # ── Template 1: nginx server config ─────────────────────────────────
      # consul-template {{ env }} fills in the dynamic port and alloc
      # paths that are only known at task-start time.
      template {
        data = <<EOT
worker_processes 1;
daemon           off;
error_log        /dev/stderr notice;
pid              {{ env "NOMAD_ALLOC_DIR" }}/nginx.pid;

events {
  worker_connections 64;
}

http {
  include      /etc/nginx/mime.types;
  default_type text/html;

  # Pipe access logs to stdout — visible via `nomad alloc logs <id>`.
  access_log /dev/stdout combined;
  sendfile   on;

  server {
    listen      {{ env "NOMAD_PORT_http" }};
    server_name _;
    root        {{ env "NOMAD_TASK_DIR" }}/www;
    index       index.html;

    # Expose allocation context in response headers for easy debugging.
    add_header X-Nomad-Job   "{{ env "NOMAD_JOB_NAME" }}"  always;
    add_header X-Nomad-Alloc "{{ env "NOMAD_ALLOC_ID" }}" always;

    # Main page: renders the Vault-sourced HTML.
    location / {}

    # Machine-readable status used by run_tests.sh.
    location /status.json {
      default_type application/json;
    }

    # Consul health check — returns 200 JSON, suppressed from access log.
    location /health {
      access_log  off;
      add_header  Content-Type application/json always;
      return 200 '{"status":"ok","job":"{{ env "NOMAD_JOB_NAME" }}","alloc":"{{ env "NOMAD_ALLOC_ID" }}"}';
    }
  }
}
EOT
        destination = "${NOMAD_ALLOC_DIR}/nginx.conf"
        change_mode = "noop"
      }

      # ── Template 2: HTML page with the Vault secret ──────────────────────
      template {
        data = <<EOT
{{ with secret "kv/data/test/hello" -}}
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>VCN Lab &#x2014; Hello</title>
  <style>
    body { font-family: monospace; max-width: 800px; margin: 2rem auto;
           padding: 0 1rem; background: #f9f9f9; color: #222; }
    h1   { border-bottom: 2px solid #333; padding-bottom: .4rem; }
    h2   { color: #444; margin-top: 1.6rem; }
    dt   { font-weight: bold; color: #555; margin-top: .5rem; }
    dd   { margin: .2rem 0 .4rem 1.2rem; }
    .ok  { color: #1a7f37; }
    code { background: #eee; padding: 0 .3rem; border-radius: 3px; }
  </style>
</head>
<body>
  <h1>&#x1F512; Vault + Consul + Nomad Lab</h1>

  <h2>Vault secret &#x2014; <code>kv/test/hello</code></h2>
  <dl>
    <dt>message</dt>
    <dd class="ok">{{ .Data.data.message }}</dd>
    <dt>rendered_at</dt>
    <dd>{{ .Data.data.rendered_at }}</dd>
  </dl>

  <h2>Nomad allocation</h2>
  <dl>
    <dt>job</dt>   <dd>{{ env "NOMAD_JOB_NAME" }}</dd>
    <dt>group</dt> <dd>{{ env "NOMAD_GROUP_NAME" }}</dd>
    <dt>task</dt>  <dd>{{ env "NOMAD_TASK_NAME" }}</dd>
    <dt>alloc</dt> <dd>{{ env "NOMAD_ALLOC_ID" }}</dd>
    <dt>port</dt>  <dd>{{ env "NOMAD_PORT_http" }}</dd>
  </dl>

  <p><a href="/status.json">status.json</a> &bull; <a href="/health">health</a></p>
</body>
</html>
{{- end }}
EOT
        destination = "${NOMAD_TASK_DIR}/www/index.html"
        change_mode = "noop"
      }

      # ── Template 3: machine-readable JSON for test assertions ─────────────
      # run_tests.sh hits /status.json and parses it with jq.
      template {
        data = <<EOT
{{ with secret "kv/data/test/hello" -}}
{
  "vault_secret": {
    "message":     "{{ .Data.data.message }}",
    "rendered_at": "{{ .Data.data.rendered_at }}"
  },
  "nomad": {
    "job":   "{{ env "NOMAD_JOB_NAME" }}",
    "group": "{{ env "NOMAD_GROUP_NAME" }}",
    "task":  "{{ env "NOMAD_TASK_NAME" }}",
    "alloc": "{{ env "NOMAD_ALLOC_ID" }}",
    "port":  "{{ env "NOMAD_PORT_http" }}"
  }
}
{{- end }}
EOT
        destination = "${NOMAD_TASK_DIR}/www/status.json"
        change_mode = "noop"
      }

      # ── Task entry point ─────────────────────────────────────────────────
      # Prints startup info (visible in `nomad alloc logs`), validates that
      # both Vault-backed templates rendered, then exec-replaces bash with
      # nginx so Nomad tracks the nginx master process directly.
      config {
        command = "/bin/bash"
        args    = ["-c", <<-EOSH
          set -eu
          echo "[hello] ===== task starting ====="
          echo "[hello] alloc  : ${NOMAD_ALLOC_ID}"
          echo "[hello] job    : ${NOMAD_JOB_NAME}"
          echo "[hello] port   : ${NOMAD_PORT_http}"
          echo "[hello] config : ${NOMAD_ALLOC_DIR}/nginx.conf"
          echo "[hello] www    : ${NOMAD_TASK_DIR}/www"

          if [ ! -s "${NOMAD_TASK_DIR}/www/index.html" ]; then
            echo "[hello] ERROR: index.html empty — vault template did not render" >&2
            exit 1
          fi
          if [ ! -s "${NOMAD_TASK_DIR}/www/status.json" ]; then
            echo "[hello] ERROR: status.json empty — vault template did not render" >&2
            exit 1
          fi

          echo "[hello] index.html  : $(wc -c < "${NOMAD_TASK_DIR}/www/index.html") bytes"
          echo "[hello] status.json : $(wc -c < "${NOMAD_TASK_DIR}/www/status.json") bytes"
          echo "[hello] ===== nginx starting on :${NOMAD_PORT_http} ====="
          exec nginx -c "${NOMAD_ALLOC_DIR}/nginx.conf"
        EOSH
        ]
      }

      resources {
        cpu    = 100
        memory = 128
      }
    }
  }
}
