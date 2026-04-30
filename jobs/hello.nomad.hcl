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

    # Tasks request a Vault token at runtime. The nomad-cluster role on
    # Vault is configured to issue tokens with the "nomad-job" policy,
    # which has read access to kv/test/*.
    vault {
      policies    = ["nomad-job"]
      change_mode = "noop"
    }

    service {
      name = "hello"
      port = "http"
      tags = ["test", "vcn-lab"]

      check {
        type     = "http"
        path     = "/"
        interval = "10s"
        timeout  = "2s"
      }
    }

    task "hello" {
      driver = "raw_exec"

      # Render the Vault secret into a file the task can read. If this
      # file is non-empty after the task starts, end-to-end Vault auth
      # from a Nomad task worked.
      template {
        data = <<EOH
{{- with secret "kv/data/test/hello" -}}
MESSAGE={{ .Data.data.message }}
RENDERED_AT={{ .Data.data.rendered_at }}
{{- end }}
EOH
        destination = "${NOMAD_SECRETS_DIR}/hello.env"
        env         = false
        change_mode = "noop"
      }

      # Tiny HTTP server in pure bash that serves the contents of the
      # rendered secret file. Avoids pulling any container image so the
      # job runs even on a minimal worker with just raw_exec.
      config {
        command = "/bin/bash"
        args = [
          "-c",
          <<-EOSH
          set -eu
          PORT="${NOMAD_PORT_http}"
          BODY_FILE="${NOMAD_SECRETS_DIR}/hello.env"
          # Pre-flight: the body file must exist (template rendered).
          test -s "$BODY_FILE" || { echo "secret not rendered" >&2; exit 1; }
          # Simple HTTP/1.0 responder using socat. apt provides socat.
          exec socat -T1 \
            TCP-LISTEN:$PORT,reuseaddr,fork \
            SYSTEM:'printf "HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\n\r\n"; cat '"$BODY_FILE"
          EOSH
        ]
      }

      resources {
        cpu    = 100
        memory = 64
      }
    }
  }
}
