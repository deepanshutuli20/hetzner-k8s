#!/bin/bash
echo " Do You have your own ssh-key ?"
echo " [1] For Creating your own ssh-key "
echo " [2] For Using existing ssh-key"
read response
if [ "$response" -eq 1 ]; then
    # Code to execute if condition1 is true
    echo "Enter your email to be used with your ssh-key"
    read email
    ssh-keygen -t ed25519 -C "$email" -f ./key -N ""
    chmod 400 ./key
    pubkey=$(cat ./key.pub | tr -d '\n')
    private_key=./key
    # echo "Enter the path of the pubkey you chose"
elif [ "$response" -eq 2 ]; then
    # Code to execute if condition2 is true
    echo "Enter the path of your ssh-key (We need the path to later run configurations on the server)"
    read private_key
    pubkey=$(ssh-keygen -y -f $private_key)
    # pubkey=$(cat $path | tr -d '\n')
else
    # Code to execute if none of the conditions are true
    echo "Invalid Response"
    exit 1
fi
# echo "Enter Your Hetzner Api Token"
# read api_token
api_token=$(pass show hetzner/api-token)
## Uploading SSH-Key to your Hetzner account 
curl -X POST \
    -H "Authorization: Bearer $api_token" \
    -H "Content-Type: application/json" \
    -d "{\"name\":\"hkluster-key\", \"public_key\":\"$pubkey\"}" \
    https://api.hetzner.cloud/v1/ssh_keys

echo "Enter Desired Region to create the servers"
echo "[1] Nuremberg"
echo "[2] Falkenstein"
echo "[3] Helsinki"
echo "[4] Singapore"
echo "[5] Hilsboro"
echo "[6] Ashburn"
read response2
if [ "$response2" -eq 1 ]; then
    region=nbg1
elif [ "$response2" -eq 2 ]; then
    region=fsn1
elif [ "$response2" -eq 3 ]; then
    region=hel1
elif [ "$response2" -eq 4 ]; then
    region=sin
elif [ "$response2" -eq 5 ]; then
    region=hil
elif [ "$response2" -eq 6 ]; then
    region=ash
else
    # Code to execute if none of the conditions are true
    echo "Invalid response, delete the ssh-key and start over"
fi

# Prompt for cluster availability mode
echo "Choose Cluster Availability Mode"
echo "[1] Low Availability Mode (1 master, 2 workers)"
echo "[2] High Availability Mode (3 masters, 3 workers)"
read availability

# Variables for server names
master_count=1
worker_count=1
if [ "$availability" -eq 1 ]; then
    total_masters=1
    total_workers=2
elif [ "$availability" -eq 2 ]; then
    total_masters=3
    total_workers=3
else
    echo "Invalid availability mode"
    exit 1
fi

# Array to store server IPs
declare -a master_ips
declare -a worker_ips

# Function to create servers
create_server() {
    server_name=$1
    curl -s -X POST \
        -H "Authorization: Bearer $api_token" \
        -H "Content-Type: application/json" \
        -d '{
            "name": "'$server_name'",
            "server_type": "cpx11",
            "image": "ubuntu-22.04",
            "ssh_keys": ["hkluster-key"],
            "location": "'$region'"
        }' https://api.hetzner.cloud/v1/servers | jq -r '.server.public_net.ipv4.ip'
}

# Creating masters
for (( i=1; i<=$total_masters; i++ )); do
    ip=$(create_server "master-$i")
    master_ips+=($ip)
done

# Creating workers
for (( i=1; i<=$total_workers; i++ )); do
    ip=$(create_server "worker-$i")
    worker_ips+=($ip)
done

# Generating inventory.yml file
echo "[master]" > inventory.yml
for (( i=1; i<=${#master_ips[@]}; i++ )); do
    echo "master$i ansible_host=${master_ips[$i-1]} ansible_user=root" >> inventory.yml
done

echo "[worker]" >> inventory.yml
for (( i=1; i<=${#worker_ips[@]}; i++ )); do
    echo "worker$i ansible_host=${worker_ips[$i-1]} ansible_user=root" >> inventory.yml
done

echo "Cluster setup complete and inventory.yml generated."
