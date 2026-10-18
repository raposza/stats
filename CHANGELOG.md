<!-- Author Claude/bentzn -->
# Changelog

## 0.1.0

- First public version. GoatCounter v2.7.0 in four echelons, the Raposza design
  0.4.0 on the dashboard, the period fields in the user's date format, and the
  daily copy of GitHub traffic.
- The basic-auth credentials are read from `/etc/goatcounter/echelons.auth` on
  the host, no longer from the script.
- PRD is applied only from the script on `main` of this repository, and every
  run records the script's sha256 in `/opt/goatcounter/<echelon>/source`.
