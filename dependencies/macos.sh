#!/bin/bash

# Function to check and install dependencies with brew
install_if_missing() {
    if ! brew list "$1" &>/dev/null; then
        echo "$1 is not installed. Installing..."
        brew install "$1"
    else
        echo "$1 is already installed."
    fi
}

# Install jq, ansible, kubectl, and helm (excluding curl and ping as they are typically preinstalled)
install_if_missing jq
install_if_missing ansible
install_if_missing kubectl
install_if_missing helm

echo "All dependencies checked and installed as needed."
