# Unraid health state-change SNMP traps

`unraid-health.sh` can send an authenticated and encrypted SNMPv3 trap to a
receiver when its overall state changes (`PASS`, `WARN`, or `FAIL`). It stores
the last successfully sent state on the Unraid flash drive, so recurring health
checks do not send another trap while the state is unchanged.

This is an alert mechanism, not a replacement for remote syslog or blackbox
logs: a frozen Tower cannot send a final trap.

## Tower prerequisites

Install the **SNMP** plugin from Unraid Community Applications. It provides
Net-SNMP, including the `snmptrap` sender. Confirm it is available:

```sh
command -v snmptrap
```

Create the protected config file outside Git:

```sh
cp /boot/config/system-logging/snmp-trap.conf.example \
  /boot/config/system-logging/snmp-trap.conf
chmod 600 /boot/config/system-logging/snmp-trap.conf
```

Edit the two passphrases. They must exactly match the Mac mini receiver.

Run `/boot/config/system-logging/unraid-health.sh` hourly. Its first successful
run sends the current state as a baseline; later runs send only changed states.

## Mac mini receiver

Install Homebrew Net-SNMP:

```sh
brew install net-snmp
```

Create `~/.snmp/snmptrapd.conf` with the same values:

```conf
createUser unraid-health SHA "AUTH_PASSPHRASE" AES "PRIVACY_PASSPHRASE"
authUser log,execute,net unraid-health priv
```

Start a foreground test receiver before making it persistent:

```sh
mkdir -p /opt/homebrew/var/log/remote
/opt/homebrew/opt/net-snmp/sbin/snmptrapd -f -Lo -C \
  -c ~/.snmp/snmptrapd.conf udp:162 \
  >> /opt/homebrew/var/log/remote/unraid-snmp-traps.log 2>&1
```

Add a persistent LaunchAgent only after the test trap has arrived.
