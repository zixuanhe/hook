#!/bin/sh
set -eu

mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
echo /sbin/mdev > /proc/sys/kernel/hotplug 2>/dev/null || true
/sbin/mdev -s 2>/dev/null || true

if [ "${1:-}" = "--oneshot" ]; then
	exit 0
fi

/sbin/mdev -d -f 2>/dev/null || true

while :; do
	sleep 3600
done
