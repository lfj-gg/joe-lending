#!/usr/bin/env python3
"""Snapshot user positions across all Banker Joe markets."""

import argparse
import os
import sys
from decimal import Decimal

import requests
from eth_abi import decode, encode
from web3 import Web3

JOETROLLER = "0xdc13687554205E5b89Ac783db14bb5bba4A1eDaC"
MULTICALL3 = "0xcA11bde05977b3631167028862bE2a173976CA11"
SUBGRAPH_ID = "JB5EdQqbddMjawMLYe3C5ifmhN9WKYvLdgAKoUy1CyYy"
BATCH_SIZE = 100
E18 = 10**18

w3 = Web3(Web3.HTTPProvider("https://api.avax.network/ext/bc/C/rpc"))

mc = w3.eth.contract(
    address=MULTICALL3,
    abi=[
        {
            "type": "function",
            "name": "aggregate3",
            "stateMutability": "payable",
            "inputs": [
                {
                    "name": "calls",
                    "type": "tuple[]",
                    "components": [
                        {"name": "target", "type": "address"},
                        {"name": "allowFailure", "type": "bool"},
                        {"name": "callData", "type": "bytes"},
                    ],
                }
            ],
            "outputs": [
                {
                    "name": "",
                    "type": "tuple[]",
                    "components": [
                        {"name": "success", "type": "bool"},
                        {"name": "returnData", "type": "bytes"},
                    ],
                }
            ],
        }
    ],
)


def encode_call(sig, *args):
    sel = w3.keccak(text=sig)[:4]
    if not args:
        return sel
    types = sig[sig.index("(") + 1 : sig.rindex(")")].split(",")
    coerced = [
        Web3.to_checksum_address(a) if t.strip() == "address" else a
        for t, a in zip(types, args)
    ]
    return sel + encode(types, coerced)


def multicall(calls):
    formatted = [
        {"target": c[0], "allowFailure": c[1], "callData": c[2]} for c in calls
    ]
    return mc.functions.aggregate3(formatted).call()


def to_decimal(value, decimals):
    return Decimal(value) / Decimal(10**decimals)


def to_usd(value):
    return Decimal(value) / Decimal(E18)


def fetch_users_subgraph(market_address):
    api_key = os.environ.get("GRAPH_API_KEY")
    if not api_key:
        raise ConnectionError("GRAPH_API_KEY not set")
    url = (
        f"https://gateway-arbitrum.network.thegraph.com/api/{api_key}"
        f"/subgraphs/id/{SUBGRAPH_ID}"
    )
    market_id = market_address.lower()
    addresses = set()
    last_id = ""
    while True:
        id_filter = f', id_gt: "{last_id}"' if last_id else ""
        query = f"""{{
          accountJTokens(
            first: 1000
            where: {{
              or: [
                {{ market: "{market_id}", jTokenBalance_gt: "0"{id_filter} }}
                {{ market: "{market_id}", storedBorrowBalance_gt: "0"{id_filter} }}
              ]
            }}
            orderBy: id, orderDirection: asc
          ) {{ id, account {{ id }} }}
        }}"""
        resp = requests.post(url, json={"query": query}, timeout=30)
        resp.raise_for_status()
        data = resp.json()
        if "errors" in data:
            raise ConnectionError(data["errors"][0]["message"])
        items = data["data"]["accountJTokens"]
        for item in items:
            addresses.add(Web3.to_checksum_address(item["account"]["id"]))
        if len(items) < 1000:
            break
        last_id = items[-1]["id"]
    return list(addresses)


def fetch_users_csv(csv_path):
    with open(csv_path) as f:
        next(f)
        return [
            Web3.to_checksum_address(line.split(",")[0]) for line in f if line.strip()
        ]


def fetch_markets():
    r0 = multicall(
        [
            (JOETROLLER, False, encode_call("getAllMarkets()")),
            (JOETROLLER, False, encode_call("oracle()")),
        ]
    )
    all_addrs = [
        Web3.to_checksum_address(a) for a in decode(["address[]"], r0[0][1])[0]
    ]
    oracle = Web3.to_checksum_address(decode(["address"], r0[1][1])[0])

    r1_calls = []
    for addr in all_addrs:
        r1_calls.extend(
            [
                (addr, False, encode_call("symbol()")),
                (addr, False, encode_call("decimals()")),
                (addr, False, encode_call("underlying()")),
                (oracle, False, encode_call("getUnderlyingPrice(address)", addr)),
            ]
        )
    r1 = multicall(r1_calls)

    markets = []
    for i, addr in enumerate(all_addrs):
        b = i * 4
        symbol = decode(["string"], r1[b][1])[0]
        underlying = Web3.to_checksum_address(decode(["address"], r1[b + 2][1])[0])
        price = decode(["uint256"], r1[b + 3][1])[0]
        markets.append(
            {
                "address": addr,
                "symbol": symbol,
                "underlying": underlying,
                "price": price,
            }
        )

    r2 = multicall(
        [(market["underlying"], False, encode_call("decimals()")) for market in markets]
    )
    for i in range(len(markets)):
        decimals = decode(["uint8"], r2[i][1])[0]
        markets[i]["decimals"] = decimals
        markets[i]["price"] = Decimal(markets[i]["price"]) / Decimal(10) ** (
            36 - decimals
        )

    return markets


def snapshot(asset):
    markets = fetch_markets()

    all_symbols = [m["symbol"] for m in markets]
    if asset not in all_symbols:
        sys.exit(f'Unknown asset "{asset}". Available: {", ".join(all_symbols)}')

    target_idx = all_symbols.index(asset)
    target = markets[target_idx]
    csv_file = f"{asset[1:].lower()}-user-positions.csv"
    print(f"Target: {asset}")

    try:
        users = fetch_users_subgraph(target["address"])
        print(f"Subgraph: {len(users)} users")
    except Exception as e:
        print(f"Subgraph unavailable ({e}), falling back to CSV...")
        if not os.path.exists(csv_file):
            sys.exit(f"No existing CSV ({csv_file})")
        users = fetch_users_csv(csv_file)
        print(f"CSV fallback: {len(users)} users")

    positions = [dict() for _ in markets]
    sum_jbal = 0
    sum_borr = 0

    for mi, market in enumerate(markets):
        is_target = mi == target_idx
        print(f"  {market['symbol']}...", end="", flush=True)

        for i in range(0, len(users), BATCH_SIZE):
            batch = users[i : i + BATCH_SIZE]
            calls = [
                (market["address"], False, encode_call("accrueInterest()")),
                (
                    market["address"],
                    False,
                    encode_call("exchangeRateStored()"),
                ),
            ]
            for addr in batch:
                calls.extend(
                    [
                        (
                            market["address"],
                            False,
                            encode_call("balanceOf(address)", addr),
                        ),
                        (
                            market["address"],
                            False,
                            encode_call("borrowBalanceStored(address)", addr),
                        ),
                        (
                            JOETROLLER,
                            False,
                            encode_call(
                                "checkMembership(address,address)",
                                addr,
                                market["address"],
                            ),
                        ),
                    ]
                )

            results = multicall(calls)
            xrate = decode(["uint256"], results[1][1])[0]

            for j, addr in enumerate(batch):
                b = 2 + j * 3
                jbal = decode(["uint256"], results[b][1])[0]
                borr = decode(["uint256"], results[b + 1][1])[0]
                member = decode(["bool"], results[b + 2][1])[0]

                if is_target:
                    sum_jbal += jbal
                    sum_borr += borr

                if jbal > 0 or borr > 0:
                    supply = jbal * xrate // E18 if jbal > 0 else 0
                    positions[mi][addr] = {
                        "supply": supply,
                        "borrow": borr,
                        "member": member,
                    }

        print(f" {len(positions[mi])} positions")

    # Sanity check
    check = multicall(
        [
            (target["address"], False, encode_call("accrueInterest()")),
            (target["address"], False, encode_call("totalSupply()")),
            (target["address"], False, encode_call("totalBorrows()")),
        ]
    )
    chain_supply = decode(["uint256"], check[1][1])[0]
    chain_borrows = decode(["uint256"], check[2][1])[0]

    supply_ok = sum_jbal == chain_supply
    diff = chain_borrows - sum_borr
    borrow_ok = diff >= 0 and (sum_borr == 0 or diff * 10**6 // sum_borr == 0)

    sep = "=" * 60
    print(f"\n{sep}\n  SANITY CHECK — {target['symbol']}\n{sep}")
    print(f"  jToken supply: {'PASS' if supply_ok else 'FAIL'}")
    print(f"    sum(balanceOf): {sum_jbal}")
    print(f"    totalSupply():  {chain_supply}")
    print(f"  Borrows:       {'PASS' if borrow_ok else 'FAIL'}")
    print(f"    sum(borrowBal): {sum_borr}")
    print(f"    totalBorrows(): {chain_borrows}")
    print(sep)

    if not supply_ok or not borrow_ok:
        print("\n  WARNING: mismatch — users may be missing.\n")

    # Write CSV
    active = [u for u in users if u in positions[target_idx]]
    print(f"\n{len(active)} active users")

    header = ["address"]
    for m in markets:
        s = m["symbol"]
        header.extend(
            [
                f"{s} (supply)",
                f"{s} (supply USD)",
                f"{s} (borrow)",
                f"{s} (borrow USD)",
                f"{s} (member)",
            ]
        )
    header.append("TOTAL (USD)")

    rows = [",".join(header)]
    for user in active:
        cells = [user]
        total_usd = Decimal(0)
        for mi, market in enumerate(markets):
            pos = positions[mi].get(user)
            if not pos:
                cells.extend(["0", "0", "0", "0", "0"])
                continue
            supply = to_decimal(pos["supply"], market["decimals"])
            borrow = to_decimal(pos["borrow"], market["decimals"])
            sup_usd = to_usd(pos["supply"] * market["price"])
            bor_usd = to_usd(pos["borrow"] * market["price"])
            cells.extend(
                [
                    str(supply),
                    str(round(sup_usd, 2)),
                    str(borrow),
                    str(round(bor_usd, 2)),
                    "1" if pos["member"] else "0",
                ]
            )
            total_usd += sup_usd - bor_usd
        cells.append(str(round(total_usd, 2)))
        rows.append(",".join(cells))

    with open(csv_file, "w") as f:
        f.write("\n".join(rows) + "\n")

    print(f"Saved to {csv_file} ({len(active)} users x {len(markets)} markets)\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Snapshot Banker Joe positions")
    parser.add_argument("asset", help="Asset symbol (e.g. jMIM)")
    snapshot(parser.parse_args().asset)
