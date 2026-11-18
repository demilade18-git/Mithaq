#!/usr/bin/env bash
# Cross-contract deployment compatibility check (CONTRACT-39).
#
# Before a deployment is accepted, verifies that ProofRegistry points at the IssuerRegistry and
# CredentialVerifier recorded for the same network, and that every referenced contract reports the
# version the deployment manifest expects. Failures name the component that mismatched.
#
# Usage:
#   ./scripts/check-cross-contract-compat.sh <deployment-manifest.json> [--network testnet|mainnet]
#                                            [--rpc-url <url>] [--source <account>]
#
# The manifest is the file written by scripts/deploy.sh (deployment-manifests/deployment-*.json).
# Needs: stellar CLI, jq.
set -euo pipefail

NETWORK="${STELLAR_NETWORK:-testnet}"
RPC_URL="${STELLAR_RPC_URL:-}"
SOURCE="${SOURCE:-}"
MANIFEST=""

while [ $# -gt 0 ]; do
  case "$1" in
    --network) NETWORK="$2"; shift 2 ;;
    --rpc-url) RPC_URL="$2"; shift 2 ;;
    --source) SOURCE="$2"; shift 2 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    -*) echo "Unknown option: $1" >&2; exit 2 ;;
    *) MANIFEST="$1"; shift ;;
  esac
done

[ -n "$MANIFEST" ] && [ -f "$MANIFEST" ] || { echo "A deployment manifest file is required" >&2; exit 2; }
for tool in stellar jq; do
  command -v "$tool" >/dev/null || { echo "$tool is required" >&2; exit 2; }
done

MISMATCHES=()
mismatch() { MISMATCHES+=("$1"); echo "MISMATCH: $1" >&2; }

manifest_get() { jq -r "$1 // empty" "$MANIFEST"; }

# The manifest must be for the network being checked, when it says which one.
manifest_network="$(manifest_get '.network')"
if [ -n "$manifest_network" ] && [ "$manifest_network" != "$NETWORK" ]; then
  mismatch "network: manifest is for '$manifest_network' but '$NETWORK' was selected"
fi

ISSUER_ID="$(manifest_get '.contracts.issuer_registry.id')"
VERIFIER_ID="$(manifest_get '.contracts.credential_verifier.id')"
REGISTRY_ID="$(manifest_get '.contracts.proof_registry.id')"
for pair in "issuer_registry:$ISSUER_ID" "credential_verifier:$VERIFIER_ID" "proof_registry:$REGISTRY_ID"; do
  [ -n "${pair#*:}" ] || mismatch "${pair%%:*}: no contract id in the manifest"
done

invoke_read() { # invoke_read <contract-id> <fn>
  local cmd=(stellar contract invoke --id "$1" --network "$NETWORK")
  [ -n "$RPC_URL" ] && cmd+=(--rpc-url "$RPC_URL")
  [ -n "$SOURCE" ] && cmd+=(--source "$SOURCE")
  "${cmd[@]}" -- "$2" 2>/dev/null | tr -d '"[:space:]'
}

# `version()` returns major*1_000_000 + minor*1_000 + patch.
decode_version() {
  local raw="$1"
  if [[ "$raw" =~ ^[0-9]+$ ]]; then
    echo "$((raw / 1000000)).$(((raw % 1000000) / 1000)).$((raw % 1000))"
  else
    echo "${raw#v}"
  fi
}

if [ -n "$REGISTRY_ID" ]; then
  # ProofRegistry's references to the other two components.
  on_chain_verifier="$(invoke_read "$REGISTRY_ID" verifier_address || true)"
  on_chain_issuer="$(invoke_read "$REGISTRY_ID" issuer_registry_address || true)"
  [ -n "$on_chain_verifier" ] || mismatch "proof_registry: could not read verifier_address from $REGISTRY_ID"
  [ -n "$on_chain_issuer" ] || mismatch "proof_registry: could not read issuer_registry_address from $REGISTRY_ID"
  if [ -n "$on_chain_verifier" ] && [ "$on_chain_verifier" != "$VERIFIER_ID" ]; then
    mismatch "proof_registry -> credential_verifier: registry points at $on_chain_verifier but the manifest has $VERIFIER_ID"
  fi
  if [ -n "$on_chain_issuer" ] && [ "$on_chain_issuer" != "$ISSUER_ID" ]; then
    mismatch "proof_registry -> issuer_registry: registry points at $on_chain_issuer but the manifest has $ISSUER_ID"
  fi
fi

# Every referenced component reports the version the manifest expects.
for name in issuer_registry credential_verifier proof_registry; do
  id="$(manifest_get ".contracts.$name.id")"
  expected="$(manifest_get ".contracts.$name.version")"
  [ -n "$id" ] && [ -n "$expected" ] || continue
  raw="$(invoke_read "$id" version || true)"
  if [ -z "$raw" ]; then
    mismatch "$name: could not read version() from $id"
    continue
  fi
  actual="$(decode_version "$raw")"
  if [ "$actual" != "$(decode_version "$expected")" ]; then
    mismatch "$name: on-chain version $actual != manifest version $expected"
  fi
done

echo
if [ "${#MISMATCHES[@]}" -gt 0 ]; then
  echo "FAIL: ${#MISMATCHES[@]} compatibility mismatch(es) on $NETWORK"
  printf ' - %s\n' "${MISMATCHES[@]}"
  exit 1
fi
echo "PASS: ProofRegistry, IssuerRegistry and CredentialVerifier are consistent on $NETWORK"
