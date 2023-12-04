#!/bin/bash

set -euo pipefail

UUID="$(cat /etc/shieldwall_id.txt)"

# proxy as workaround for distributed firewall not able to use the default push model
# see: https://github.com/prometheus-community/PushProx/tree/master
PROXY_ARGS="--fqdn=${UUID}.box.shieldwall --proxy-url=http://controller.shieldwall:900 --metrics-addr=127.0.0.1:9101 --log.level=warn"
# shellcheck disable=SC2086
/usr/local/bin/prometheus_proxy_client $PROXY_ARGS &

# prometheus node-exporter for system-stats/-metrics
METRICS_SYS='--collector.cpu --collector.diskstats --collector.filesystem --collector.loadavg
--collector.meminfo --collector.stat --collector.vmstat'
METRICS_HW='--collector.edac --collector.hwmon --collector.nvme --collector.mdadm --collector.thermal_zone
--collector.cpu_vulnerabilities'
METRICS_NET='--collector.arp --collector.bonding --collector.conntrack --collector.netclass
--collector.netdev --collector.netstat --collector.sockstat --collector.softnet --collector.udp_queues
--collector.ethtool --collector.network_route'
METRICS_SYS_INFO='--collector.sysctl --collector.systemd --collector.os --collector.uname'
METRICS_ARGS='--log.level=warn --web.listen-address=127.0.0.1:9100 --web.config.file=/etc/prometheus_node_exporter.yml'

# shellcheck disable=SC2086
/usr/local/bin/prometheus_node_exporter $METRICS_ARGS $METRICS_SYS $METRICS_HW $METRICS_NET $METRICS_SYS_INFO
