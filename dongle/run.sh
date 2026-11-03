#!/system/bin/sh
# Keep sms37.sh running; started at boot by /system/etc/install-recovery.sh.
# Run it with busybox sh: mksh hides fd 9 from flock.
D=/data/local/sms37
export PATH=$D/bin:/system/bin:/system/xbin
exec 9> $D/lock
flock -n 9 || exit 0                      # already running
while true; do
    sh $D/sms37.sh >> $D/log 2>&1 9>&-
    echo "$(date '+%Y-%m-%d %H:%M:%S') bridge stopped (exit $?), restarting in 10s" >> $D/log
    sleep 10
done
