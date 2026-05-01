#!/usr/bin/env python3
"""Build Safe multisig transactions calling SimpleEscrow.set() from escrow.json.

Splits the user list into chunks of at most --chunk-size users (default 1000)
and writes one multisig file per chunk, with the Safe nonce auto-incremented
starting from the current on-chain nonce.

Output format matches 6-lfj-ops.json: a single ABI-encoded call per file.

Usage:
    uv run script/build_escrow_set_ops.py --escrow 0xEscrow...
"""

import argparse
import json
import sys
import time
from pathlib import Path

from eth_abi import encode
from web3 import Web3

REPO_ROOT = Path(__file__).resolve().parent.parent

# jToken symbol → underlying token address on Avalanche C-Chain. Sourced from
# asset.md; SimpleEscrow keys claims by underlying, not by jToken.
UNDERLYING = {
    "jAVAX": "0xB31f66AA3C1e785363F0875A1B74E27b85FD66c7",  # WAVAX
    "jWETH": "0x49D5c2BdFfac6CE2BFdB6640F4F80f226bc10bAB",  # WETH.e
    "jWBTC": "0x50b7545627a5162F82A992c33b87aDc75187B218",  # WBTC.e
    "jUSDC": "0xA7D7079b0FEaD91F3e65f86E8915Cb59c1a4C664",  # USDC.e
    "jUSDT": "0xc7198437980c041c805A1EDcbA50c1Ce5db95118",  # USDT.e
    "jDAI": "0xd586E7F844cEa2F87f50152665BCbc2C279D8d70",  # DAI.e
    "jLINK": "0x5947BB275c521040051D82396192181b413227A3",  # LINK.e
    "jUSDTNative": "0x9702230A8Ea53601f5cD2dc00fDBc13d4dF4A8c7",
    "jXJOE": "0x57319d41F71E81F3c65F2a47CA4e001EbAFd4F33",
    "jUSDCNative": "0xB97EF9Ef8734C71904D8002F8b6Bc66Dd9c48a6E",
    "jJOE": "0x6e84a6216eA6dACC71eE8E6b0a5B7322EEbC0fDd",
    "jBTC": "0x152b9d0FdC40C096757F570A51E494bd4b943E50",  # BTC.b
}

DEFAULT_SAFE = "0xF1D58a13f87C2c9f26a277fF2c0E382Bd7776323"
DEFAULT_RPC = "https://api.avax.network/ext/bc/C/rpc"
CHAIN_ID = 43114

SET_SIGNATURE = "set((address,address,uint256)[])"

# ABI fragment for the `set` call, embedded in each output file alongside the
# encoded calldata so signers can decode-and-verify before approving.
SET_FUNCTION_ABI = {
    "type": "function",
    "name": "set",
    "inputs": [
        {
            "name": "positions",
            "type": "tuple[]",
            "components": [
                {"name": "user", "type": "address"},
                {"name": "token", "type": "address"},
                {"name": "amount", "type": "uint256"},
            ],
        }
    ],
    "outputs": [],
    "stateMutability": "nonpayable",
}


def get_safe_nonce(w3: Web3, safe: str) -> int:
    """Read `nonce()` directly from the Safe contract storage."""
    selector = Web3.keccak(text="nonce()")[:4]
    result = w3.eth.call({"to": safe, "data": selector})
    return int.from_bytes(result, "big")


def encode_set(positions: list[tuple[str, str, int]]) -> str:
    selector = Web3.keccak(text=SET_SIGNATURE)[:4]
    body = encode(["(address,address,uint256)[]"], [positions])
    return "0x" + (selector + body).hex()


def build_positions(
    users: list[str], escrow_data: dict[str, dict[str, int]]
) -> list[tuple[str, str, int]]:
    out: list[tuple[str, str, int]] = []
    for user in users:
        user_cs = Web3.to_checksum_address(user)
        for sym, amount in escrow_data[user].items():
            token = Web3.to_checksum_address(UNDERLYING[sym])
            out.append((user_cs, token, int(amount)))
    return out


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--escrow", required=True, help="SimpleEscrow contract address")
    ap.add_argument("--safe", default=DEFAULT_SAFE, help="Safe (multisig) address")
    ap.add_argument(
        "--input",
        default=str(REPO_ROOT / "escrow.json"),
        help="Input JSON file (default: <repo>/escrow.json)",
    )
    ap.add_argument(
        "--output-dir",
        default=str(REPO_ROOT),
        help="Directory for output files (default: <repo>)",
    )
    ap.add_argument(
        "--chunk-size", type=int, default=1000, help="Max users per multisig file"
    )
    ap.add_argument("--rpc", default=DEFAULT_RPC, help="JSON-RPC URL")
    ap.add_argument(
        "--threshold", type=int, default=2, help="Safe signing threshold to record"
    )
    args = ap.parse_args()

    with open(args.input) as f:
        escrow_data = json.load(f)

    unknown = {
        sym for holdings in escrow_data.values() for sym in holdings if sym not in UNDERLYING
    }
    if unknown:
        sys.exit(f"unknown jToken symbol(s) in {args.input}: {sorted(unknown)}")

    users = sorted(escrow_data.keys(), key=str.lower)
    chunks = [users[i : i + args.chunk_size] for i in range(0, len(users), args.chunk_size)]

    w3 = Web3(Web3.HTTPProvider(args.rpc))
    safe = Web3.to_checksum_address(args.safe)
    escrow = Web3.to_checksum_address(args.escrow)
    base_nonce = get_safe_nonce(w3, safe)

    total_positions = sum(len(h) for h in escrow_data.values())
    print(f"safe {safe} current nonce: {base_nonce}")
    print(
        f"input: {len(users)} users, {total_positions} positions → "
        f"{len(chunks)} file(s) (<= {args.chunk_size} users each)"
    )

    for i, chunk in enumerate(chunks):
        positions = build_positions(chunk, escrow_data)
        nonce = base_nonce + i
        ops = {
            "version": "1.0.0",
            "chain_id": CHAIN_ID,
            "nonce": nonce,
            "created_at": int(time.time()),
            "threshold": args.threshold,
            "safe_address": safe,
            "signatures": [],
            "calls": [
                {
                    "to": escrow,
                    "value": "0x0",
                    "data": encode_set(positions),
                    "function": SET_FUNCTION_ABI,
                }
            ],
        }
        out_path = Path(args.output_dir) / f"tx_lending_{CHAIN_ID}_{nonce}.json"
        out_path.parent.mkdir(parents=True, exist_ok=True)
        with out_path.open("w") as f:
            json.dump(ops, f, indent=4)
        print(
            f"  {out_path}: {len(chunk)} users, "
            f"{len(positions)} positions, nonce={nonce}"
        )


if __name__ == "__main__":
    main()
