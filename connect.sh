#!/bin/bash

# Replace with your actual jump server hostname or IP address
jump_server="jumpserver"

# Replace with the actual port number on the jump server
jump_server_port=6443

# Replace with the actual destination hostname or IP address
destination_host="10.0.1.1"

# Replace with the actual destination port number
destination_port=6443

# Construct the SSH command with background execution and error redirection
ssh_command="ssh -L ${jump_server_port}:${destination_host}:${destination_port} -N ${jump_server} 2>&1 > /dev/null &"

# Run the SSH command in the background
eval "$ssh_command"

# Print a success message
echo "Tunnel created successfully!"

# Print instructions on how to verify and terminate the tunnel
echo "To verify the tunnel, you can use:"
echo "ssh -p ${jump_server_port} localhost"

echo "To terminate the tunnel, use:"
echo "pkill -f 'ssh -L ${jump_server_port}:${destination_host}:${destination_port} -N ${jump_server}'"
