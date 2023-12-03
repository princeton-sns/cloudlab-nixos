#!/bin/sh

# Identify the boot disk based on the mounted root partition. Only do
# this on the first deploy to remain stable, independent of the new
# configuration:
if [ ! -f "$1/boot-disk" ]; then
  basename $(readlink -f "/sys/class/block/$(mount | grep "/nix/store" | cut -d " " -f1 | sed -e "s|^/dev||")/..") > "$1/boot-disk"
  echo "Identified boot disk as $(cat "$1/boot-disk")"
fi

# Identify the experiment network link by searching for the first
# LOWER_UP interface which is not used for the default gateway and
# not the loopback link. We only do this on the first deploy (as
# the new configuration may change some of these attributes).
if [ ! -f "$1/experiment-link" ]; then
  CONTROL_LINK="$(ip -4 route show default | sed -E "s/^.* dev ([a-zA-Z0-9]+) .*$/\\1/")"
  echo "Identified control link as $CONTROL_LINK"
  ip link | grep -E '^[0-9]+:' | grep -v -E "[0-9]+: $CONTROL_LINK:" | grep -v "[0-9]: lo:" | grep "LOWER_UP" | head -n1 | sed -E "s/^[0-9]: ([a-zA-Z0-9]+): .*$/\\1/" > "$1/experiment-link"
  echo "Identified experiment link as $(cat "$1/experiment-link")"
fi
