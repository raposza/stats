<!-- Author Claude/bentzn -->
# Changelog

## 0.4.0

- The dashboard's Pages list in two groups, Web pages and GitHub, each with
  its own header and visit count, on the one page.

## 0.3.0

- The daily GitHub copy also counts the downloads of the release assets of
  every public repository, one counter per repository,
  `github.com/raposza/<repo> download`. Draft releases and checksum and
  signature files are not counted.

## 0.2.0

- PRD serves the dashboard instead of a placeholder page. Its own GoatCounter
  login guards it, as on every echelon.

## 0.1.0

- First public version. GoatCounter v2.7.0 in four echelons, the Raposza design
  0.4.0 on the dashboard, the period fields in the user's date format, and the
  daily copy of GitHub traffic.
- The basic-auth credentials are read from `/etc/goatcounter/echelons.auth` on
  the host, no longer from the script.
- PRD is applied only from the script on `main` of this repository, and every
  run records the script's sha256 in `/opt/goatcounter/<echelon>/source`.
