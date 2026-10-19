<!-- Author Claude/bentzn -->
# Raposza Stats

Visitor statistics for the Raposza web sites and the public `raposza` GitHub
repositories: [GoatCounter](https://github.com/arp242/goatcounter), self-hosted
on `raposza.com`, with one dashboard covering every site.

This repository is what runs. `install-goatcounter.sh` is the whole
deployment: it installs GoatCounter, writes the nginx configuration, the
dashboard's Raposza styling and date fields, and the copier that brings GitHub
traffic into the dashboard. Nothing else on the host shapes what a visitor or a
dashboard user sees.

## What is counted, and what is kept

- Page views on the Raposza sites, counted by a small script the page loads
  from its own site. No cookie is set and no IP address is stored. A unique
  visitor is a hash of user agent, IP address and a daily salt, and the hash
  itself is not stored. Country is derived from the IP address when the visit
  is counted.
- GitHub traffic of every public `raposza` repository, once a day: each day's
  unique visitors become that many visits to `github.com/raposza/<repo>`, and
  each day's unique cloners become events named
  `github.com/raposza/<repo> clone`. GitHub's total views and clones and its
  referrers are not copied. Private repositories are not counted.
- Downloads of the release assets of every public `raposza` repository, in the
  same daily run: GitHub keeps one running total per file and no dates, so
  what a total grew by since the last run becomes that many events named
  `github.com/raposza/<repo> download`, dated at the run. A file seen for the
  first time brings its whole total, dated when the file was uploaded. Draft
  releases and checksum and signature files are not counted.
- The page path carries the site's host - `net.raposza.com/api.html` - which
  is what puts every site on one dashboard.

## How a site is counted

A browser only ever talks to the site it is on. Inside the site's nginx
`server { }` block:

```
include /etc/nginx/goatcounter-<echelon>.inc;
```

and in every page, the same in every echelon:

```
<script data-goatcounter="/_gc/count" async src="/_gc/count.js"></script>
```

The include serves `/_gc/count.js` from the site and passes `/_gc/count` to
GoatCounter on the loopback interface, so a site's Content Security Policy
needs nothing beyond `'self'`.

## Echelons

| Echelon | Dashboard | Access |
| --- | --- | --- |
| DEV | `https://dev.stats.raposza.com` | basic auth |
| STG | `https://stg.stats.raposza.com` | basic auth |
| RC | `https://rc.stats.raposza.com` | basic auth |
| PRD | `https://stats.raposza.com` | public; the dashboard behind GoatCounter's own login |

Each echelon is its own GoatCounter instance with its own database. A change is
tried on DEV first. PRD is installed only from the `install-goatcounter.sh`
that is on `main` of this repository: the script refuses to apply PRD when its
own sha256 differs from that file's. Every run records the script's sha256 on
the host, and for PRD the commit it came from.

## The dashboard

The dashboard follows the Raposza design
([github.com/raposza/design](https://github.com/raposza/design)): nginx serves
a `vars.css` that maps every GoatCounter colour to a Raposza token, with Inter
and Hack as the fonts. The two period fields show dates in the format the user
chose under Settings, Preferences; GoatCounter itself shows them in the
browser's locale or as `yyyy-mm-dd`.

## Running it

On the host, as root:

```
sudo bash install-goatcounter.sh --echelon dev|stg|rc|prd|all [--apply] [--email <dashboard login>]
```

Without `--apply` it reports and changes nothing. It is safe to rerun: a file is
written only when its content differs. It needs Rocky Linux 9 or similar with
nginx, certbot with an account, `curl`, `openssl`, `python3` and `git`, and the
hostnames resolving to the host.

Files it expects, which are never in this repository:

| File | Holds |
| --- | --- |
| `/etc/goatcounter/echelons.auth` | the basic-auth `user:password` for DEV, STG and RC, root 0600 |
| `/etc/goatcounter/github.token` | a fine-grained GitHub token, Repository permission Administration: Read-only; without it the GitHub copier is installed but not enabled |

## Licence

Apache License 2.0, see `LICENSE`. GoatCounter is downloaded from its own
releases and is under its own licence.
