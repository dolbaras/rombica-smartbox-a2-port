#!/bin/bash
# Append UART output to $1 for up to 2 hours, reopening the port if the adapter reconnects.
end=$((SECONDS+7200))
while [ $SECONDS -lt $end ]; do
    stty -F /dev/ttyUSB0 115200 cs8 -cstopb -parenb raw -echo -ixon -crtscts 2>/dev/null \
        && timeout $((end-SECONDS)) cat /dev/ttyUSB0 >> "$1" 2>/dev/null
    sleep 0.3
done
