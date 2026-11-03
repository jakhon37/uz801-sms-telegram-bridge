#!/system/bin/sh
# Run by init at every boot (service flash_recovery). Starts the sms37 bridge.
/system/bin/busybox setsid /system/bin/busybox sh /data/local/sms37/run.sh </dev/null >/dev/null 2>&1 &
