#!/bin/bash

# Execute lsof for the given port
output=$(lsof -i :6443)

# Extract the PID from the output. Assumes that the PID is on the second line and in the second column.
pid=$(echo "$output" | awk 'NR==2 {print $2}')

# Check if we got a PID
if [ -z "$pid" ]; then
    echo "No process found listening on port 6443."
    exit 1
else
    # Kill the process with the found PID
    kill -9 $pid
    echo "Process with PID $pid has been killed."
fi
