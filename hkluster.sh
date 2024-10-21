#!/bin/bash

echo "Do You have your own ssh-key?"
echo "[1] For Creating your own ssh-key"
echo "[2] For Using existing ssh-key"
read response

if [ "$response" -eq 1 ]; then
    echo "Enter your email to be used with your ssh-key"
    read email
    ssh-keygen -t ed25519 -C "$email" -f ./key -N ""
    chmod 400 ./key
    pubkey=$(cat ./key.pub | tr -d '\n')
    private_key=./key
elif [ "$response" -eq 2 ]; then
    echo "Enter the path of your ssh-key (We need the path to later run configurations on the server)"
    read private_key
    pubkey=$(ssh-keygen -y -f $private_key)
else
    echo "Invalid Response"
    exit 1
fi

# Hetzner API token
api_token=$(pass show hetzner/api-token)

# Uploading SSH-Key to Hetzner account
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
    network_zone=eu-central
elif [ "$response2" -eq 2 ]; then
    region=fsn1
    network_zone=eu-central
elif [ "$response2" -eq 3 ]; then
    region=hel1
    network_zone=eu-central
elif [ "$response2" -eq 4 ]; then
    region=sin
    network_zone=ap-southeast
elif [ "$response2" -eq 5 ]; then
    region=hil
    network_zone=us-west
elif [ "$response2" -eq 6 ]; then
    region=ash
    network_zone=us-east
else
    echo "Invalid response, delete the ssh-key and start over"
    exit 1
fi

# Create private network 'kubernetes-cluster' using the correct region as network zone first
network=$(curl -X POST \
    -H "Authorization: Bearer $api_token" \
    -H "Content-Type: application/json" \
    -d '{
        "expose_routes_to_vswitch": false,
        "ip_range": "10.0.0.0/16",
        "labels": {
            "environment": "prod",
            "example.com/my": "label",
            "just-a-key": ""
        },
        "name": "kubernetes-cluster",
        "routes": [
            {
                "destination": "10.100.1.0/24",
                "gateway": "10.0.1.1"
            }
        ],
        "subnets": [
            {
                "ip_range": "10.0.1.0/24",
                "network_zone": "'$network_zone'",
                "type": "cloud"
            }
        ]
    }' https://api.hetzner.cloud/v1/networks
)
network_id=$(echo "$network" |jq -r '.network.id')

# Check if the network was created successfully
if [ -z "$network_id" ]; then
    echo "Network creation failed. Exiting."
    exit 1
fi

# Now prompt for cluster availability mode
echo "Choose Cluster Availability Mode"
echo "[1] Low Availability Mode (1 master, 2 workers)"
echo "[2] High Availability Mode (3 masters, 3 workers)"
read availability

# Variables for server names
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

# Create the jumpserver with both public and private IPs, attached to the private network
jumpserver_ip=$(curl -s -X POST \
    -H "Authorization: Bearer $api_token" \
    -H "Content-Type: application/json" \
    -d '{
        "name": "jumpserver",
        "server_type": "cpx11",
        "image": "ubuntu-22.04",
        "ssh_keys": ["hkluster-key"],
        "location": "'$region'",
        "networks": ["'$network_id'"],  
        "public_net": {
            "enable_ipv4": true,
            "enable_ipv6": true
        }
    }' https://api.hetzner.cloud/v1/servers | jq -r '.server.public_net.ipv4.ip')

# Ensure the jumpserver is created successfully before proceeding
if [ -z "$jumpserver_ip" ]; then
    echo "Jumpserver creation failed. Exiting."
    exit 1
fi

# Function to create master and worker servers in the private network without public IPs
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
            "location": "'$region'",
            "networks": ["'$network_id'"],
            "public_net": {
                "enable_ipv4": false,
                "enable_ipv6": false
            }
        }' https://api.hetzner.cloud/v1/servers | jq -r '.server.private_net[0].ip'
}

# Creating master servers
declare -a master_ips
for (( i=1; i<=$total_masters; i++ )); do
    ip=$(create_server "master-$i")
    if [ -z "$ip" ]; then
        echo "Failed to create master-$i. Exiting."
        exit 1
    fi
    master_ips+=($ip)
done

# Creating worker servers
declare -a worker_ips
for (( i=1; i<=$total_workers; i++ )); do
    ip=$(create_server "worker-$i")
    if [ -z "$ip" ]; then
        echo "Failed to create worker-$i. Exiting."
        exit 1
    fi
    worker_ips+=($ip)
done

# Generating inventory.yml file
echo "[jumpserver]" > inventory.yml
echo "jumpserver ansible_host=$jumpserver_ip ansible_user=root" >> inventory.yml

echo "[master]" >> inventory.yml
for (( i=1; i<=${#master_ips[@]}; i++ )); do
    echo "master$i ansible_host=${master_ips[$i-1]} ansible_user=root" >> inventory.yml
done

echo "[worker]" >> inventory.yml
for (( i=1; i<=${#worker_ips[@]}; i++ )); do
    echo "worker$i ansible_host=${worker_ips[$i-1]} ansible_user=root" >> inventory.yml
done

echo "Cluster setup complete and inventory.yml generated."
