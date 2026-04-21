import argparse
import json
import os
from collections import defaultdict
from decimal import ROUND_UP, Decimal
from math import ceil

import pandas as pd
from dotenv import load_dotenv
from snapshot import snapshot
from web3 import Web3

w3 = Web3(Web3.HTTPProvider("https://api.avax.network/ext/bc/C/rpc"))
JOETROLLER = "0xdc13687554205E5b89Ac783db14bb5bba4A1eDaC"
MULTICALL3 = "0xcA11bde05977b3631167028862bE2a173976CA11"
FUNDING_BUFFER = Decimal("0.1")  # 10% buffer
DEFAULT_MAX_BATCH = 40
MAX_REPAY_PERCENT = Decimal("1.05")  # 5% more than the bad debt
LIQUIDATE = "liquidate"
REPAY = "repayBorrowBehalf"
REDEEM = "transferAndRedeem"


def parse(markets, field, value):
    if field == "address":
        return value
    if field.endswith("(member)"):
        return value == "1"
    symbol = field.split(" ")[0]
    return Decimal(value) * markets[symbol]["price"]


def load_joetroller(w3):
    with open("out/Joetroller.sol/Joetroller.json") as f:
        joetroller_abi = json.load(f)["abi"]
    return w3.eth.contract(address=JOETROLLER, abi=joetroller_abi)


def load_oracle(w3, joetroller):
    with open("out/PriceOracle.sol/PriceOracle.json") as f:
        oracle_abi = json.load(f)["abi"]
    return w3.eth.contract(address=joetroller.functions.oracle().call(), abi=oracle_abi)


def load_markets(w3, joetroller, oracle):
    with open("out/JCollateralCapErc20.sol/JCollateralCapErc20.json") as f:
        jtoken_abi = json.load(f)["abi"]
    markets = {}
    for market in joetroller.functions.getAllMarkets().call():
        m = w3.eth.contract(address=market, abi=jtoken_abi)
        symbol = m.functions.symbol().call()
        underlying = m.functions.underlying().call()
        decimals = (
            w3.eth.contract(address=underlying, abi=jtoken_abi)
            .functions.decimals()
            .call()
        )
        markets[symbol] = {
            "address": market,
            "underlying": underlying,
            "decimals": decimals,
            "collateralFactor": Decimal(joetroller.functions.markets(market).call()[1])
            / 10**18,
            "price": Decimal(oracle.functions.getUnderlyingPrice(market).call())
            / 10 ** (36 - decimals),
        }
    return markets


def load_positions(markets):
    with open(f"{ASSET[1:].lower()}-user-positions.csv") as f:
        fields = f.readline().strip().split(",")
        positions = {}
        for line in f:
            values = line.strip().split(",")
            positions[values[0]] = {
                fields[i]: parse(markets, fields[i], values[i])
                for i in range(1, len(fields))
                if not fields[i].endswith("USD)")
            }
        positions = pd.DataFrame(positions)
    return positions


def get_values(markets, position) -> (dict, dict, Decimal, Decimal, Decimal):
    (collaterals, borrows) = ({}, {})
    (total_collateral, total_borrow) = (Decimal(0), Decimal(0))
    for key, value in position.items():
        if value == 0:
            continue
        (symbol, side) = key.split(" ")
        market = markets[symbol]
        if side == "(supply)" and position[f"{symbol} (member)"]:
            collateral = value * market["collateralFactor"]
            collaterals[symbol] = collateral
            total_collateral += collateral
        elif side == "(borrow)":
            borrow = value
            borrows[symbol] = borrow
            total_borrow += borrow

    collaterals = dict(
        list(sorted(collaterals.items(), key=lambda x: x[1], reverse=True))
    )
    borrows = dict(list(sorted(borrows.items(), key=lambda x: x[1], reverse=True)))

    if ASSET not in collaterals:
        collaterals[ASSET] = Decimal(0)
    if ASSET not in borrows:
        borrows[ASSET] = Decimal(0)

    return (collaterals, borrows, total_collateral, total_borrow)


def get_action(markets, positions, user, dust):
    (asset_supply, asset_borrow) = (
        positions.loc[f"{ASSET} (supply)", user],
        positions.loc[f"{ASSET} (borrow)", user],
    )
    if asset_supply == 0 and asset_borrow == 0:
        return None
    (collaterals, borrows, total_collateral, total_borrow) = get_values(
        markets, positions[user]
    )

    # User deposited ASSET and has no borrows OR
    # the user deposited ASSET, didn't use it as collateral and has a positive health factor,
    # redeem
    if asset_supply > 0 and (
        total_borrow == 0
        or (
            (
                not positions.loc[f"{ASSET} (member)", user]
                and total_collateral / total_borrow > 1
            )
            or (
                asset_borrow == 0
                and (total_collateral - collaterals[ASSET]) / total_borrow >= 1
            )
        )
    ):
        positions.loc[f"{ASSET} (supply)", user] = 0
        return (REDEEM, (ASSET))

    # User has borrowed ASSET and has some supplies, liquidate the ASSET against the supply
    if asset_borrow > 0 and total_collateral > 0:
        borrow = borrows[ASSET]
        (asset, collateral) = next(iter(collaterals.items()))
        if collateral > dust:
            supply = positions.loc[f"{asset} (supply)", user]
            liquidation = borrow * LIQUIDATION_PREMIUM
            if liquidation < supply:
                asset_needed = liquidation
                positions.loc[f"{ASSET} (borrow)", user] = Decimal(0)
                positions.loc[f"{asset} (supply)", user] -= liquidation
            else:
                asset_needed = supply
                liquidation = supply / LIQUIDATION_PREMIUM
                positions.loc[f"{ASSET} (borrow)", user] -= liquidation
                positions.loc[f"{asset} (supply)", user] = dust
            return (LIQUIDATE, (ASSET, asset, asset_needed))

    # User has supplied ASSET and has some borrows,
    # liquidate the borrow against the ASSET
    if asset_supply > dust and total_borrow > 0:
        supply = positions.loc[f"{ASSET} (supply)", user]
        (asset, borrow) = next(iter(borrows.items()))
        liquidation = borrow * LIQUIDATION_PREMIUM
        if liquidation < supply:
            asset_needed = liquidation
            positions.loc[f"{asset} (borrow)", user] = Decimal(0)
            positions.loc[f"{ASSET} (supply)", user] -= liquidation
        else:
            asset_needed = supply
            liquidation = supply / LIQUIDATION_PREMIUM
            positions.loc[f"{asset} (borrow)", user] -= liquidation
            positions.loc[f"{ASSET} (supply)", user] = dust
        return (LIQUIDATE, (asset, ASSET, asset_needed))

    # User has no collateral, but some ASSET borrows, repay the bad debt
    if total_collateral == 0 and asset_borrow > 0:
        positions.loc[f"{ASSET} (borrow)", user] = Decimal(0)
        return (REPAY, (ASSET, asset_borrow))

    # User has deposited ASSET, but has more borrows than collateral,
    # need to repay the other asset bad debt
    if total_collateral < total_borrow and asset_supply < total_borrow:
        (asset, borrow) = next(iter(borrows.items()))
        repay = borrow
        if total_collateral - asset_supply > total_borrow - repay:
            repay = total_borrow - (total_collateral - asset_supply)
            current = positions.loc[f"{asset} (borrow)", user]
            # If the repay is more than 99.99% of the borrow,
            # repay the entire borrow to avoid leaving dust
            if repay / current >= 0.9999:
                repay = current
            positions.loc[f"{asset} (borrow)", user] -= repay
        else:
            positions.loc[f"{asset} (borrow)", user] = Decimal(0)
        return (REPAY, (asset, repay))

    return "unknown", None


def get_user_actions(markets, positions):
    dust = Decimal(10) ** -markets[ASSET]["decimals"]

    df = positions.copy()

    needed = defaultdict(Decimal)
    bad_debt = defaultdict(Decimal)

    user_actions = defaultdict(list)

    max_iter_per_users = 50
    for user in df.columns:
        nb_iter = 0
        while True:
            result = get_action(markets, df, user, dust)
            if result is None:
                break
            (action, details) = result
            if action == "unknown":
                raise Exception(f"Unknown action for user {user}")
            if action == REPAY:
                (asset, amount_usd) = details
                user_actions[user].append(
                    {
                        "action": action,
                        "asset": asset,
                        "maxRepay": amount_usd
                        * MAX_REPAY_PERCENT
                        / markets[asset]["price"],
                    }
                )
                bad_debt[asset] += amount_usd
            elif action == LIQUIDATE:
                (borrow, collateral, amount_usd) = details
                asset = borrow
                user_actions[user].append(
                    {
                        "action": action,
                        "borrow": borrow,
                        "collateral": collateral,
                    }
                )
            elif action == REDEEM:
                asset = details
                amount_usd = 0
                user_actions[user].append(
                    {
                        "action": action,
                        "asset": asset,
                    }
                )
            else:
                raise Exception(f"Unknown action: {action}")

            buffered_amount_usd = amount_usd * (1 + FUNDING_BUFFER)
            needed[asset] += buffered_amount_usd

        nb_iter += 1
        if nb_iter == max_iter_per_users:
            raise Exception(f"Max iterations per user reached for user {user}")

    print("Fund needed")
    sum_needed = 0
    for asset, amount in needed.items():
        sum_needed += amount
        print(f"{asset}: ${round(amount, 2)}")
    print(f"total ${round(sum_needed, 2)}")

    print("\nBad debt")
    for asset, amount in bad_debt.items():
        print(f"{asset}: ${round(amount, 2)}")
    print(f"total ${round(sum(bad_debt.values()), 2)}")

    user_actions = dict(
        sorted(user_actions.items(), key=lambda x: action_priority(x[1]))
    )
    return user_actions, needed


# Order actions by positive impact on the market
def action_priority(actions):
    types = {a["action"] for a in actions}
    # First, only liquidations and repays as they only decrease borrows
    if types <= {LIQUIDATE, REPAY}:
        return 0
    # Second, actions that contain at least a liquidation
    if LIQUIDATE in types:
        return 1
    # Third, actions that contain a redeem
    if REDEEM in types:
        return 2
    raise Exception(f"Unexpected action types: {types}")


def get_batches(markets, user_actions):
    batches = []
    batch = None
    nb_actions = 0
    for user, actions in user_actions.items():
        if len(actions) > MAX_BATCH:
            raise Exception(f"User {user} has {len(actions)} actions")
        if len(batches) == 0 or nb_actions + len(actions) > MAX_BATCH:
            nb_actions = 0
            batches.append({REDEEM: [], LIQUIDATE: [], REPAY: []})
            batch = batches[-1]
        for a in actions:
            nb_actions += 1
            if a["action"] == REDEEM:
                batch[REDEEM].append(
                    {"jToken": markets[a["asset"]]["address"], "user": user}
                )
            elif a["action"] == LIQUIDATE:
                batch[LIQUIDATE].append(
                    {
                        "jTokenBorrowed": markets[a["borrow"]]["address"],
                        "jTokenCollateral": markets[a["collateral"]]["address"],
                        "user": user,
                    }
                )
            elif a["action"] == REPAY:
                market = markets[a["asset"]]
                maxRepay = ceil(a["maxRepay"] * Decimal(10) ** market["decimals"])
                batch[REPAY].append(
                    {"jToken": market["address"], "maxRepay": maxRepay, "user": user}
                )
    return batches


def save_action_plan(markets, needed, batches):
    actions = {
        "targetJToken": markets[ASSET]["address"],
        "targetSymbol": ASSET,
        "totalFunding": {
            "tokens": [
                {
                    "token": markets[asset]["underlying"],
                    "symbol": asset[1:],
                    "amount": str(
                        (amount / markets[asset]["price"]).quantize(
                            Decimal(10) ** -markets[asset]["decimals"],
                            rounding=ROUND_UP,
                        )
                    ),
                    "decimals": markets[asset]["decimals"],
                    "amountUsd": str(amount),
                }
                for asset, amount in needed.items()
            ],
            "totalUsd": str(sum(needed.values())),
        },
        "batchCount": len(batches),
        "batches": batches,
    }

    with open(f"{ASSET[1:].lower()}-action-plan.json", "w") as f:
        json.dump(actions, f, indent=2)


def main(asset, batch_size, rerun_snapshot):
    load_dotenv()
    global LIQUIDATION_PREMIUM
    LIQUIDATION_PREMIUM = Decimal(os.getenv("TRUSTED_LIQUIDATION_PREMIUM"))
    global ASSET
    ASSET = asset
    global MAX_BATCH
    MAX_BATCH = batch_size

    if rerun_snapshot:
        snapshot(asset)

    print(f"Processing {ASSET} market...")

    joetroller = load_joetroller(w3)
    oracle = load_oracle(w3, joetroller)
    markets = load_markets(w3, joetroller, oracle)

    if asset not in markets:
        raise Exception(
            f"Unknown asset: {asset}. Available assets: {', '.join(markets.keys())}"
        )

    positions = load_positions(markets)
    user_actions, needed = get_user_actions(markets, positions)
    batches = get_batches(markets, user_actions)

    save_action_plan(markets, needed, batches)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("asset", type=str, help="Banker Joe asset symbol (e.g. jMIM)")
    parser.add_argument(
        "--batch-size",
        type=int,
        default=DEFAULT_MAX_BATCH,
        help="Maximum number of actions per batch",
    )
    parser.add_argument("--rerun", action="store_true", help="Rerun the snapshot")
    args = parser.parse_args()

    main(args.asset, args.batch_size, args.rerun)
