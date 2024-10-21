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

#Creating a Server
curl -X POST \
    -H "Authorization: Bearer $api_token" \
    -H "Content-Type: application/json" \
    -d '{
        "name": "sample-server",
        "server_type": "cpx11", 
        "image": "ubuntu-22.04",
        "ssh_keys": ["hkluster-key"],
        "location": "'$region'"
    }' \
    https://api.hetzner.cloud/v1/servers
