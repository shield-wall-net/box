# ShieldWall - Box

Setup-Scripts and library to run a centrally manageable network firewall (*box*)

ShieldWall firewalls are designed to be [managed centrally by their linked controller](https://github.com/shield-wall-net/controller).

## WARNING: Development still in progress!

----

## Box

- [ ] NFTables firewall
- [ ] DNS Server
- [ ] DHCP Server
- [ ] Logging
  - [ ] Rsyslog & Logrotate
  - [ ] Forwarding to controller
- [ ] Squid Proxy
  - [ ] Being able to process HTTP+S
  - [ ] SSL-Bump mode
  - [ ] SSL-Intercept mode
- [ ] Routing
  - [ ] Static
  - [ ] Gateway-Groups
- [ ] VPN
  - [ ] Client to Site
    - [ ] OpenVPN
    - [ ] WireGuard
  - [ ] Site to Site
    - [ ] WireGuard
    - [ ] IPSec
- [ ] High Availability
  - [ ] DHCP (*Lease sync*)
  - [ ] Sync connection tracking
  - [ ] Shared IPs (*VRRP/VIP*)

----

## Setup

Designed to run on:
* [Debian 12 netinstall](https://www.debian.org/CD/netinst/)
* no Desktop environment (*GUI*)
* installed without `standard system utilities`
* using `deb.debian.org` as repository

You may want to use LVM and use partitioning like this:

```bash
/sda
- /sda1 => ext4 /boot (512 MB)
- /sda2 => LVM

vg0
- lv1 => ext4 / (min 5 GB)
- lv2 => ext4 /var (min 5 GB)
- lv3 => swap (min 1 GB)
```

Run the setup-script:
