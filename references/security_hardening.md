# BoF Reference: Linux Security Hardening & Perimeter Defense

This runbook provides defense-in-depth auditing and hardening procedures for Linux servers, SSH daemons, host firewalls, reverse proxies (HAProxy/Nginx), intrusion prevention (CrowdSec/Fail2Ban), and encrypted tunnels.

---

## 1. Perimeter & Listening Socket Audit

Before changing any firewall rule, map every listening port and verify whether it is bound to `0.0.0.0` / `::` (all interfaces) vs `127.0.0.1` / private VLAN:
```bash
ss -tulnp
```

### 1.1 The Docker Firewall Bypass Trap (`0.0.0.0:PORT`)
- **Critical Vulnerability:** Publishing a container port in Docker (`-p 27017:27017` or `ports: ["5432:5432"]`) manipulates `iptables`/`nftables` `nat`/`PREROUTING` chains directly, **bypassing `ufw` and `firewalld` input rules completely**!
- **Remediation:**
  1. Bind internal container ports strictly to localhost or a private management IP in `docker-compose.yml`:
     ```yaml
     ports:
       - "127.0.0.1:5432:5432"
     ```
  2. Or use the `DOCKER-USER` chain in `iptables`/`nftables` to enforce host-level IP allowlists before Docker rules evaluate.

---

## 2. SSH Daemon Hardening (`sshd`)

> **Safety Warning (Lockout Prevention):**
> 1. Before disabling password authentication, verify that at least one valid public key exists in `~/.ssh/authorized_keys` with strict permissions (`chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys`).
> 2. Always back up `/etc/ssh/sshd_config`, test with `sshd -t`, and keep your current SSH session open while testing a new login in a second terminal!

### Recommended Drop-In (`/etc/ssh/sshd_config.d/99-bof-hardening.conf`)
```sshconfig
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
MaxAuthTries 3
LoginGraceTime 30
ClientAliveInterval 60
ClientAliveCountMax 3
X11Forwarding no
AllowTcpForwarding yes
```
Validate before reload:
```bash
sshd -t && systemctl reload sshd || systemctl reload ssh
```

---

## 3. Reverse Proxy Hardening (HAProxy & Nginx)

### 3.1 TLS Cipher & Protocol Hardening
- **Eliminate Legacy Ciphers:** Audit configs for `3DES`, `RC4`, `MD5`, `TLSv1.0`, and `TLSv1.1`.
- **Enforce Modern TLS 1.2 / 1.3 (Mozilla Intermediate Profile):**
  ```haproxy
  # HAProxy global section
  ssl-default-bind-options ssl-min-ver TLSv1.2 no-tls-tickets
  ssl-default-bind-ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305
  ```

### 3.2 Slowloris & Connection Exhaustion Mitigation
- **The Trap:** Setting `timeout client 600s` or `client_body_timeout 3600s` globally allows attackers (or stuck mobile clients) to exhaust proxy file descriptors with slow requests.
- **The Fix:** Use tight global defaults (`timeout connect 5s`, `timeout client 30s`, `timeout server 60s`) and isolate legitimate long-lived routes (WebSockets, large file uploads, SSH tunnels) into dedicated backends/locations with scoped timeouts.

### 3.3 Layer-7 Rate Limiting & SSH Brute-Force Protection in HAProxy
- Never leave a `stick-table` defined in a backend without active `track-sc` and `deny`/`tarpit` rules in the frontend!
- **HTTP Rate Limiting Example:**
  ```haproxy
  frontend www-https
      http-request track-sc0 src table Abuse
      http-request deny deny_status 429 if { sc_http_req_rate(0,Abuse) gt 100 }
  ```
- **SSH TCP Proxy Rate Limiting Example:**
  ```haproxy
  frontend ssh-proxy
      mode tcp
      option tcplog
      stick-table type ip size 100k expire 10m store conn_rate(1m),conn_cur
      tcp-request connection track-sc0 src
      tcp-request connection reject if { sc0_conn_rate gt 10 } || { sc0_conn_cur gt 5 }
  ```

### 3.4 CORS & Content-Security-Policy (CSP)
- **Ban Blind Origin Reflection:** Never echo the incoming `Origin` header unconditionally into `Access-Control-Allow-Origin` (which is equivalent to `*` with credentials). Match against an explicit regex/ACL allowlist of trusted domains.
- **Progressive CSP Rollout:** Always deploy new CSP policies using `Content-Security-Policy-Report-Only` first so third-party fonts, scripts, or maps are audited in browser consoles before enforcing hard blocks.

---

## 4. Active Intrusion Prevention (CrowdSec & Fail2Ban)

When deploying or auditing CrowdSec on reverse proxies:
1. **Verify Both Halves:** CrowdSec requires both the **Security Engine** (log parser/LAPI) AND a **Remediation Bouncer** (`crowdsec-nginx-bouncer`, `crowdsec-firewall-bouncer-nftables`, or HAProxy Lua bouncer). One without the other does nothing.
2. **Prevent False-Positive Self-DoS (Tile Servers / Polling APIs):**
   - Web map servers (e.g., Leaflet/OpenStreetMap tile servers) and HTMX polling dashboards legitimately fire 30–80 rapid requests per page load, triggering `crowdsecurity/http-crawl-non_statics` or aggressive Nginx `limit_req` rules.
   - Always create a parser/postoverflow whitelist for static tile paths (`/tiles/`, `.pbf`, `.png`) and use **Simulation Mode** (`cscli simulation enable`) when introducing new scenarios in production.

---

## 5. Zero-Trust Tunnels & Encrypted Management (Chisel mTLS / WireGuard)

When exposing edge nodes behind NAT/CGNAT (e.g., Raspberry Pi, Odroid, remote sites) to a central relay:
1. **Enforce Mutual TLS (mTLS):** Always use `--tls-ca`, `--tls-cert`, and `--tls-key` on both server and client so unauthorized clients cannot register reverse ports.
2. **Bind Reverse Ports to `127.0.0.1` on the Relay:** On the public VPS, bind reverse tunnel ports to `127.0.0.1:<port>` (never `0.0.0.0:<port>`) and terminate public traffic through Nginx/HAProxy with TLS + Basic Auth/OAuth, or access via SSH ProxyJump.
3. **Protect `.env` Credentials:** Store tunnel credentials and `--auth` secrets in `/etc/default/<service>` or `.env` with `chmod 600` owned by `root:root`, and ensure `.env` is listed in `.gitignore`.
4. **Systemd Resilience:** Configure `Restart=always`, `RestartSec=5`, and `StartLimitIntervalSec=0` so transient WAN drops never permanently kill the management tunnel.
