<!-- Author Claude/bentzn -->
# Security

Reviewed 2026-10-19 for v0.3.0.

## Reporting a vulnerability

Write to info@raposza.com. A report sent by any other route may not reach
anyone.

Include what you did, what happened and what you expected, in enough detail to
reproduce it. No response time is promised.

## What this is, for the purpose of a report

`install-goatcounter.sh` installs four GoatCounter instances on one host, one
per echelon, and the nginx configuration in front of them. It runs as root and
is run by hand; nothing on the host updates it.

## What listens

- Each GoatCounter instance listens on `127.0.0.1` only, plain HTTP, ports
  30810, 30820, 30830 and 30840. It runs as the system user `goatcounter` under
  systemd with `NoNewPrivileges`, `PrivateTmp`, `ProtectHome` and
  `ProtectSystem=strict`, writing only its own data directory.
- nginx answers each dashboard host on port 443 with a Let's Encrypt
  certificate and `Strict-Transport-Security`. Port 80 serves the ACME
  challenge and redirects everything else to 443.
- DEV, STG and RC require basic auth on the whole 443 server. That keeps
  pre-release echelons away from the public; it is not meant as a strong
  control, and the password is shared with the other Raposza pre-release
  sites. PRD is public.
- Every dashboard has GoatCounter's own login on top: an email address and a
  password generated per echelon at install.
- Hostnames are published in certificate transparency logs when certificates
  are issued, so every echelon's host name is known.

## What a counted site exposes

A site that includes `/etc/nginx/goatcounter-<echelon>.inc` serves
`/_gc/count.js` (GoatCounter's own `count.js` with one settings line in front)
and passes `/_gc/count` to its echelon's GoatCounter on loopback. On the way:

- `Host` is forced to the dashboard host, so a page cannot choose which
  instance it counts into;
- `X-Real-Ip` and `X-Forwarded-For` are set to the connecting address, and
  `Cf-Connecting-Ip`, `Fly-Client-Ip` and `X-Azure-Socketip` are cleared,
  because GoatCounter trusts them and a client could otherwise send its own;
- `Authorization` is cleared, so a site's basic-auth header never reaches
  GoatCounter.

GoatCounter sets no cookie on a visitor and stores no IP address; see
`README.md`.

## Credentials, and where they live

None of them is in this repository.

| What | Where on the host | Can do |
| --- | --- | --- |
| basic-auth `user:password` | `/etc/goatcounter/echelons.auth`, root 0600; hashed with apr1 into `/etc/nginx/raposza-echelons.htpasswd`, root:nginx 0640 | open DEV, STG and RC |
| dashboard login per echelon | `/etc/goatcounter/<echelon>.txt`, root 0600 | administer that echelon's GoatCounter |
| GoatCounter API token per echelon | `/etc/goatcounter/<echelon>.api`, root:goatcounter 0640 | count hits into that echelon, nothing else |
| GitHub token, shared | `/etc/goatcounter/github.token`, root:goatcounter 0640 | read repository traffic: fine-grained, Administration read-only |

The GitHub copier runs daily as `goatcounter`, reads from `api.github.com`
with the GitHub token and posts to its echelon's GoatCounter on loopback with
that echelon's API token. Besides the traffic it reads the releases of the
public repositories, which need no permission, and keeps the download totals
it has seen in `/var/lib/goatcounter/<echelon>/gh-downloads.json`.

## What the install trusts

- The GoatCounter binary, downloaded from its GitHub release and checked
  against a sha256 pinned in the script; a mismatch stops the install.
- `com.raposza.design:raposza-design`, downloaded from Maven Central and
  checked against a sha256 pinned in the script; only its CSS, SVG, font and
  licence files are used.
- For PRD, the copy of the script on `main` of this repository, read
  anonymously: PRD is applied only when the running script is byte for byte
  that file.
