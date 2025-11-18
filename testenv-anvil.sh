# MIT License
#
# Copyright (c) 2025 Chorus One
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

#!/bin/bash
set -e

# Start Anvil in the background
echo "Starting Anvil fork..."
make start-fork > anvil.log 2>&1 &
ANVIL_PID=$!

# Setup cleanup trap
cleanup() {
    echo "Cleaning up..."
    if kill -0 $ANVIL_PID 2>/dev/null; then
        echo "Stopping Anvil (PID: $ANVIL_PID)"
        kill $ANVIL_PID
    fi
}
trap cleanup EXIT INT TERM

echo "Anvil started with PID: $ANVIL_PID"

# Wait for Anvil to be ready
echo "Waiting for Anvil to be ready..."
RPC_URL="http://localhost:9123"
MAX_RETRIES=30
RETRY_COUNT=0

while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if curl -s -X POST -H "Content-Type: application/json" \
        --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
        "$RPC_URL" > /dev/null 2>&1; then
        echo "Anvil is ready!"
        break
    fi
    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [ $RETRY_COUNT -eq $MAX_RETRIES ]; then
        echo "Error: Anvil failed to start after $MAX_RETRIES attempts"
        exit 1
    fi
    echo "Waiting for Anvil... ($RETRY_COUNT/$MAX_RETRIES)"
    sleep 1
done

# Set environment variables
export FOUNDRY_PROFILE="test"
export RPC_URL="http://localhost:9123"

# Initialize and deploy Lido core
echo "Initializing Lido core..."
make core-init

echo "Deploying Lido core contracts..."
make core-deploy

# Extract and export CORE_LOCATOR_ADDRESS
echo "Extracting CORE_LOCATOR_ADDRESS..."
export CORE_LOCATOR_ADDRESS=$(jq -r '.lidoLocator.proxy.address' lido-core/deployed-local.json)

if [ -z "$CORE_LOCATOR_ADDRESS" ] || [ "$CORE_LOCATOR_ADDRESS" = "null" ]; then
    echo "Error: Failed to extract CORE_LOCATOR_ADDRESS from lido-core/deployed-local.json"
    exit 1
fi

echo "CORE_LOCATOR_ADDRESS: $CORE_LOCATOR_ADDRESS"
echo "RPC_URL: $RPC_URL"

# Verify the connection is still alive
echo "Verifying RPC connection..."
if ! curl -s -X POST -H "Content-Type: application/json" \
    --data '{"jsonrpc":"2.0","method":"eth_blockNumber","params":[],"id":1}' \
    "$RPC_URL" > /dev/null 2>&1; then
    echo "Error: Lost connection to Anvil"
    exit 1
fi

# Run integration tests
echo "You can now run integration tests with: make test-integration"
echo "RPC_URL=$RPC_URL CORE_LOCATOR_ADDRESS=$CORE_LOCATOR_ADDRESS make test-integration"
echo
echo "Run Morpho tests:"
echo "FOUNDRY_PROFILE=test CORE_LOCATOR_ADDRESS=$CORE_LOCATOR_ADDRESS \\"
echo "forge test --match-contract MorphoLoopStrategyTest -vvvvv --fork-url http://localhost:9123"
echo
echo 'Will sleep for "forever"'
sleep 999999999
