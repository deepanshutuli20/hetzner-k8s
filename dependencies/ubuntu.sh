#!/bin/bash

# Update package list
sudo apt update

# Function to check and install dependencies with apt
install_if_missing() {
    if ! dpkg -s "$1" &>/dev/null; then
        echo "$1 is not installed. Installing..."
        sudo apt install -y "$1"
    else
        echo "$1 is already installed."
    fi
}

# Install dependencies
install_if_missing jq
install_if_missing curl
install_if_missing ansible
install_if_missing iputils-ping

echo "All dependencies checked and installed as needed."
