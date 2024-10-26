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
    here=$(pwd)
    private_key=$here/key
elif [ "$response" -eq 2 ]; then
    echo "Enter the path of your ssh-key (We need the path to later run configurations on the server)"
    read private_key
    pubkey=$(ssh-keygen -y -f $private_key)
else
    echo "Invalid Response"
    exit 1
fi

echo "Enter API Token"
read api_token
# # Hetzner API token
# api_token=$(pass show hetzner/api-token)

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

#Create a Function add ip route to the network 

curl -X POST "https://api.hetzner.cloud/v1/networks/$network_id/actions/add_route" \
-H "Authorization: Bearer $api_token" \
-H "Content-Type: application/json" \
-d '{
  "destination": "0.0.0.0/0",
  "gateway": "10.0.1.1"
}'

# Function to create master and worker servers in the private network without public IPs
create_server() {
    server_name=$1
    curl -s -X POST \
        -H "Authorization: Bearer $api_token" \
        -H "Content-Type: application/json" \
        -d '{
            "name": "'$server_name'",
            "server_type": "cpx21",
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
    last_worker_ip=${worker_ips[${#worker_ips[@]}-1]}
done

# Generating inventory.yml file
echo "[jumpserver]" > inventory.yml
echo "jumpserver ansible_host=$jumpserver_ip ansible_user=root" >> inventory.yml
echo "" >> inventory.yml

echo "[master]" >> inventory.yml
for (( i=1; i<=${#master_ips[@]}; i++ )); do
    echo "master$i ansible_host=${master_ips[$i-1]} ansible_user=root" >> inventory.yml
done
echo "" >> inventory.yml

echo "[worker]" >> inventory.yml
for (( i=1; i<=${#worker_ips[@]}; i++ )); do
    echo "worker$i ansible_host=${worker_ips[$i-1]} ansible_user=root" >> inventory.yml
done
echo "" >> inventory.yml


echo "[master:vars]" >> inventory.yml
echo "ansible_ssh_common_args='-o ProxyCommand=\"ssh -W %h:%p -q -i $private_key root@$jumpserver_ip\" -p 22 -i $private_key'" >> inventory.yml
echo "" >> inventory.yml
echo "[worker:vars]" >> inventory.yml
echo "ansible_ssh_common_args='-o ProxyCommand=\"ssh -W %h:%p -q -i $private_key root@$jumpserver_ip\" -p 22 -i $private_key'" >> inventory.yml

echo "Inventory.yml generated."
echo "Last ip is $last_worker_ip"
echo "Checking Server Reachability"

## Generate function to check the reachability of the servers 
# Function to ping the jumphost directly
ping_jumphost() {
  ping -c 4 $jumpserver_ip > /dev/null 2>&1
  return $?
}

# Function to ping the private server through the jumphost
ping_private_server() {
  ssh -i $private_key -o StrictHostKeyChecking=no root@$jumpserver_ip "ping -c 4 $last_worker_ip" > /dev/null 2>&1
  return $?
}

# Set the maximum time to keep trying (10 minutes = 600 seconds)
TIMEOUT=600
START_TIME=$(date +%s)

# Step 1: Check if jumphost is reachable
echo "Checking if jumphost is reachable..."

while true; do
  # Calculate the elapsed time
  CURRENT_TIME=$(date +%s)
  ELAPSED_TIME=$((CURRENT_TIME - START_TIME))

  # Check if we've hit the 10-minute mark
  if [ $ELAPSED_TIME -ge $TIMEOUT ]; then
    echo "Timeout: Jumphost still unreachable after 10 minutes."
    exit 1
  fi

  # Attempt to ping the jumphost
  ping_jumphost
  if [ $? -eq 0 ]; then
    echo "Jumphost reachable"
    break
  else
    echo "Jumphost unreachable, retrying in 5 seconds..."
    sleep 5  # Wait for 5 seconds before trying again
  fi
done

# Step 2: Check if private server is reachable through the jumphost
echo "Checking if private server is reachable through the jumphost..."

START_TIME=$(date +%s)  # Reset the start time for private server check

while true; do
  # Calculate the elapsed time
  CURRENT_TIME=$(date +%s)
  ELAPSED_TIME=$((CURRENT_TIME - START_TIME))

  # Check if we've hit the 10-minute mark
  if [ $ELAPSED_TIME -ge $TIMEOUT ]; then
    echo "Timeout: Private server still unreachable after 10 minutes."
    exit 1
  fi

  # Attempt to ping the private server through the jumphost
  ping_private_server
  if [ $? -eq 0 ]; then
    echo "Private server reachable"
    break
  else
    echo "Private server unreachable, retrying in 5 seconds..."
    sleep 5  # Wait for 5 seconds before trying again
  fi
done

# Running ansible playbook to configure NAT Gateway on private nodes
ansible-playbook -i inventory.yml playbooks/set_nat.yml --private-key $private_key

# Running Playbook to configure load-balancing on haproxy-server
ansible-playbook -i inventory.yml playbooks/haproxy.yml --private-key $private_key

#Running ansbible playbook to configure the primary master server and retrieve node_token
ansible-playbook -i inventory.yml playbooks/master_main.yml --private-key $private_key

master_main_ip=$(ansible-inventory -i inventory.yml --host master1 | grep "ansible_host" | cut -d ":" -f 2 | tr -d '," ')

#Copy the node-token to enable joining the cluster
scp -i $private_key \
    -o StrictHostKeyChecking=no \
    -o ProxyCommand="ssh -i $private_key -W %h:%p root@$jumpserver_ip -o StrictHostKeyChecking=no" \
    root@$master_main_ip:/var/lib/rancher/rke2/server/node-token .
node_token=$(cat ./node-token)

#Copy the kubeconfig file to later interact with the cluster
scp -i $private_key \
    -o StrictHostKeyChecking=no \
    -o ProxyCommand="ssh -i $private_key -W %h:%p root@$jumpserver_ip -o StrictHostKeyChecking=no" \
    root@$master_main_ip:/etc/rancher/rke2/rke2.yaml ./kubeconfig

#Adjusting permissions on kubeconfig
chmod 600 ./kubeconfig
    
#Check For Pre-Existing Variable FIles
if [ -f playbooks/variables.yml ]; then
    truncate -s 0 playbooks/variables.yml
fi

# Configuring ansible variables file
echo "node_token: $node_token" > playbooks/variables.yml

#Configuring other master nodes in the cluster in case of high availability
if [ "$availability" -eq 2 ]; then
    ansible-playbook -i inventory.yml playbooks/master_node.yml --private-key $private_key
fi

#Configuring Worker Nodes
ansible-playbook -i inventory.yml playbooks/worker_node.yml --private-key $private_key

#Configuring ssh config entry for jumpserver
echo -e "Host jumpserver\n\tHostName $jumpserver_ip\n\tIdentityFile $private_key\n\tUser root" >> ~/.ssh/config

sleep 10
#Some Messages
ssh -L 6443:10.0.1.1:6443 -N jumpserver 2>&1 > /dev/null &
sleep 5
export KUBECONFIG=./kubeconfig
kubectl -n kube-system create secret generic hcloud --from-literal=token=$api_token --from-literal=network=kubernetes-cluster
helm repo add hcloud https://charts.hetzner.cloud
helm repo update hcloud
helm install hccm hcloud/hcloud-cloud-controller-manager -n kube-system --set networking.enabled=true
echo "************Now just change the line 341 of manifests/deploy.yaml to the following*****************"
echo "load-balancer.hetzner.cloud/location: $region"
echo "After that run kubectl apply -f manifests/deploy.yml"
echo "This Will Also enable an Ingress for you"
echo "The Following is an output of kubectl get nodes command"
kubectl get nodes
echo "Run export KUBECONFIG=./kubeconfig"
echo "Then run connect.sh to connect to your kubernetes cluster"
echo "To Disconnet from the cluster network run disconnect.sh"
./disconnect.sh > /dev/null 2>&1 &