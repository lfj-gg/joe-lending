#!/usr/bin/env python3
"""Snapshot user positions across all Banker Joe markets."""

import argparse
import os
import sys
from decimal import Decimal

import requests
from dotenv import load_dotenv
from eth_abi import decode, encode
from web3 import Web3

load_dotenv()

JOETROLLER = "0xdc13687554205E5b89Ac783db14bb5bba4A1eDaC"
MULTICALL3 = "0xcA11bde05977b3631167028862bE2a173976CA11"
SUBGRAPH_ID = "JB5EdQqbddMjawMLYe3C5ifmhN9WKYvLdgAKoUy1CyYy"
BATCH_SIZE = 100
E18 = 10**18
E36 = 10**36

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
    return mc.functions.aggregate3(formatted).call(block_identifier=BLOCK)


def to_decimal(value, decimals):
    return Decimal(value) / Decimal(10**decimals)


def to_usd(raw_amount, raw_price):
    # Oracle price mantissa is scaled so raw_amount * raw_price is always in 1e36
    # (price = real_price * 10**(36 - underlying_decimals)), regardless of decimals.
    return Decimal(raw_amount * raw_price) / Decimal(E36)


def fmt_usd(value):
    # 2-decimal by default; switch to scientific for non-zero values that would round to 0.
    if value == 0:
        return "0"
    rounded = value.quantize(Decimal("0.01"))
    if rounded != 0:
        return str(rounded)
    return f"{value:.2E}"


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


def fetch_users_all_markets(markets):
    addresses = set()
    for market in markets:
        print(f"  {market['symbol']}...", end="", flush=True)
        market_users = fetch_users_subgraph(market["address"])
        addresses.update(market_users)
        print(f" {len(market_users)} users (total unique: {len(addresses)})")
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
        markets[i]["decimals"] = decode(["uint8"], r2[i][1])[0]

    return markets


def snapshot(asset):
    global BLOCK
    BLOCK = os.getenv("BLOCK")
    if BLOCK is None:
        BLOCK = "latest"
    else:
        BLOCK = int(BLOCK)
    print(f"Using block {BLOCK}")

    markets = fetch_markets()
    all_symbols = [m["symbol"] for m in markets]

    is_all = asset.lower() == "all"
    if is_all:
        csv_file = "all-user-positions.csv"
        sanity_idxs = list(range(len(markets)))
        print("Target: all markets")
    else:
        if asset not in all_symbols:
            sys.exit(
                f'Unknown asset "{asset}". Available: {", ".join(all_symbols)}, all'
            )
        target_idx = all_symbols.index(asset)
        csv_file = f"{asset[1:].lower()}-user-positions.csv"
        sanity_idxs = [target_idx]
        print(f"Target: {asset}")

    try:
        if is_all:
            users = fetch_users_all_markets(markets)
        else:
            users = fetch_users_subgraph(markets[target_idx]["address"])
        print(f"Subgraph: {len(users)} users")
    except Exception as e:
        print(f"Subgraph unavailable ({e}), falling back to CSV...")
        if not os.path.exists(csv_file):
            sys.exit(f"No existing CSV ({csv_file})")
        users = fetch_users_csv(csv_file)
        print(f"CSV fallback: {len(users)} users")

    positions = [dict() for _ in markets]
    sum_jbal = [0] * len(markets)
    sum_borr = [0] * len(markets)
    track_sum = set(sanity_idxs)

    for mi, market in enumerate(markets):
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

                if mi in track_sum:
                    sum_jbal[mi] += jbal
                    sum_borr[mi] += borr

                if jbal > 0 or borr > 0:
                    supply = jbal * xrate // E18 if jbal > 0 else 0
                    positions[mi][addr] = {
                        "supply": supply,
                        "borrow": borr,
                        "member": member,
                    }

        print(f" {len(positions[mi])} positions")

    # Sanity check — totalSupply/totalBorrows/totalReserves per market.
    # Classifies each market to surface phantom debt and the top-up needed
    # (transfer + gulp) to cover market-side ghosts at redemption time.
    sanity_calls = []
    for mi in sanity_idxs:
        sanity_calls.extend(
            [
                (markets[mi]["address"], False, encode_call("accrueInterest()")),
                (markets[mi]["address"], False, encode_call("totalSupply()")),
                (markets[mi]["address"], False, encode_call("totalBorrows()")),
                (markets[mi]["address"], False, encode_call("totalReserves()")),
            ]
        )
    sanity_results = multicall(sanity_calls)

    summaries = []
    for k, mi in enumerate(sanity_idxs):
        b = k * 4
        chain_supply = decode(["uint256"], sanity_results[b + 1][1])[0]
        chain_borrows = decode(["uint256"], sanity_results[b + 2][1])[0]
        reserves = decode(["uint256"], sanity_results[b + 3][1])[0]
        market = markets[mi]

        supply_diff = chain_supply - sum_jbal[mi]
        borrow_diff = chain_borrows - sum_borr[mi]
        borrow_diff_usd = to_usd(borrow_diff, market["price"])
        reserves_usd = to_usd(reserves, market["price"])

        if supply_diff != 0:
            status, topup_usd, ghost_usd = "SUPPLY_MISMATCH", Decimal(0), Decimal(0)
        elif borrow_diff == 0:
            status, topup_usd, ghost_usd = "OK", Decimal(0), Decimal(0)
        elif borrow_diff > 0:
            reserve_gap = borrow_diff - reserves
            if reserve_gap <= 0:
                status, topup_usd, ghost_usd = "COVERED", Decimal(0), Decimal(0)
            else:
                status = "TOPUP"
                topup_usd = to_usd(reserve_gap, market["price"])
                ghost_usd = Decimal(0)
        else:
            status = "USER_GHOST"
            topup_usd = Decimal(0)
            ghost_usd = -borrow_diff_usd

        summaries.append(
            {
                "mi": mi,
                "symbol": market["symbol"],
                "chain_supply": chain_supply,
                "chain_borrows": chain_borrows,
                "supply_diff": supply_diff,
                "borrow_diff": borrow_diff,
                "borrow_diff_usd": borrow_diff_usd,
                "reserves": reserves,
                "reserves_usd": reserves_usd,
                "status": status,
                "topup_usd": topup_usd,
                "ghost_usd": ghost_usd,
            }
        )

    severity = {
        "SUPPLY_MISMATCH": 0,
        "TOPUP": 1,
        "USER_GHOST": 2,
        "COVERED": 3,
        "OK": 4,
    }
    summaries.sort(key=lambda s: (severity[s["status"]], -s["topup_usd"]))

    sep = "=" * 60
    print(f"\n{sep}\n  SANITY CHECK\n{sep}")
    current_status = None
    for s in summaries:
        if s["status"] != current_status:
            current_status = s["status"]
            print(f"\n  --- {current_status} ---")
        if s["status"] == "TOPUP":
            tag = f"TOPUP {fmt_usd(s['topup_usd'])}"
        elif s["status"] == "USER_GHOST":
            tag = f"USER_GHOST {fmt_usd(s['ghost_usd'])}"
        else:
            tag = s["status"]
        sign = "+" if s["borrow_diff"] > 0 else ""
        print(f"\n  {s['symbol']} [{tag}]")
        print(
            f"    supply:   sum={sum_jbal[s['mi']]}, chain={s['chain_supply']}, "
            f"diff={s['supply_diff']}"
        )
        print(
            f"    borrow:   sum={sum_borr[s['mi']]}, chain={s['chain_borrows']}, "
            f"diff={s['borrow_diff']} ({sign}{fmt_usd(s['borrow_diff_usd'])} USD)"
        )
        print(f"    reserves: {s['reserves']} (~{fmt_usd(s['reserves_usd'])} USD)")

    topups = [s for s in summaries if s["status"] == "TOPUP"]
    ghosts = [s for s in summaries if s["status"] == "USER_GHOST"]
    supply_bad = [s for s in summaries if s["status"] == "SUPPLY_MISMATCH"]

    print(f"\n{sep}\n  SUMMARY\n{sep}")
    counts = {k: 0 for k in severity}
    for s in summaries:
        counts[s["status"]] += 1
    for k in ["OK", "COVERED", "TOPUP", "USER_GHOST", "SUPPLY_MISMATCH"]:
        if counts[k]:
            print(f"  {k}: {counts[k]} market(s)")

    if topups:
        total = sum((s["topup_usd"] for s in topups), Decimal(0))
        print(f"\n  TOP-UP REQUIRED (transfer + gulp before redeems): {fmt_usd(total)}")
        width = max(len(s["symbol"]) for s in topups)
        for s in sorted(topups, key=lambda x: x["topup_usd"], reverse=True):
            print(f"    {s['symbol']:<{width}}  {fmt_usd(s['topup_usd'])}")

    if ghosts:
        total = sum((s["ghost_usd"] for s in ghosts), Decimal(0))
        print(f"\n  USER-SIDE PHANTOM (clamp repays, leaves dust): {fmt_usd(total)}")
        width = max(len(s["symbol"]) for s in ghosts)
        for s in sorted(ghosts, key=lambda x: x["ghost_usd"], reverse=True):
            print(f"    {s['symbol']:<{width}}  {fmt_usd(s['ghost_usd'])}")

    if supply_bad:
        print("\n  SUPPLY MISMATCH — subgraph likely missing users:")
        for s in supply_bad:
            print(f"    {s['symbol']}: diff={s['supply_diff']}")
    print(sep)

    # Write CSV
    if is_all:
        seen = {u for mi in range(len(markets)) for u in positions[mi]}
        active = [u for u in users if u in seen]
    else:
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
            sup_usd = to_usd(pos["supply"], market["price"])
            bor_usd = to_usd(pos["borrow"], market["price"])
            cells.extend(
                [
                    str(supply),
                    fmt_usd(sup_usd),
                    str(borrow),
                    fmt_usd(bor_usd),
                    "1" if pos["member"] else "0",
                ]
            )
            total_usd += sup_usd - bor_usd
        cells.append(fmt_usd(total_usd))
        rows.append(",".join(cells))

    with open(csv_file, "w") as f:
        f.write("\n".join(rows) + "\n")

    print(f"Saved to {csv_file} ({len(active)} users x {len(markets)} markets)\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Snapshot Banker Joe positions")
    parser.add_argument("asset", help="Asset symbol (e.g. jMIM)")
    snapshot(parser.parse_args().asset)
