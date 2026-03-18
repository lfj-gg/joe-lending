const { task, types } = require("hardhat/config");
const fs = require("fs");
const path = require("path");

const JOETROLLER = "0xdc13687554205E5b89Ac783db14bb5bba4A1eDaC";
const MULTICALL3 = "0xcA11bde05977b3631167028862bE2a173976CA11";

const JOETROLLER_ABI = [
  "function getAllMarkets() view returns (address[])",
  "function markets(address) view returns (bool, uint256)",
  "function oracle() view returns (address)",
];

const JTOKEN_ABI = [
  "function symbol() view returns (string)",
  "function underlying() view returns (address)",
];

const MULTICALL_ABI = [
  "function aggregate3(" +
    "tuple(address target, bool allowFailure, bytes callData)[] calls" +
    ") returns (tuple(bool success, bytes returnData)[])",
];

const NATIVE_SYMBOLS = new Set(["jAVAX"]);
const MIN_HEALTH_RATIO = 1.20;

let ethers;

function parsePositionsCsv(filePath) {
  const lines = fs.readFileSync(filePath, "utf8").trim().split("\n");
  const header = lines[0].split(",");

  const markets = [];
  for (let i = 1; i < header.length - 1; i += 2) {
    const m = header[i].replace(" (amount)", "");
    markets.push(m);
  }

  const users = [];
  for (let i = 1; i < lines.length; i++) {
    const cols = lines[i].split(",");
    const address = cols[0];
    const positions = {};

    for (let mi = 0; mi < markets.length; mi++) {
      const amount = parseFloat(cols[1 + mi * 2]) || 0;
      const usd = parseFloat(cols[2 + mi * 2]) || 0;
      if (amount !== 0 || usd !== 0) {
        positions[markets[mi]] = { amount, usd };
      }
    }

    const totalUsd = parseFloat(cols[cols.length - 1]) || 0;
    users.push({ address, positions, totalUsd });
  }

  return { markets, users };
}

function classify(user, targetSymbol, collateralFactors) {
  const target = user.positions[targetSymbol] || {
    amount: 0,
    usd: 0,
  };
  const hasSupply = target.amount > 0;
  const hasBorrow = target.amount < 0;
  const targetUsd = Math.abs(target.usd);

  if (!hasSupply && !hasBorrow) {
    return null;
  }

  const supplies = [];
  const borrows = [];

  for (const [market, pos] of Object.entries(user.positions)) {
    if (market === targetSymbol) continue;
    if (pos.amount > 0) {
      supplies.push({ market, ...pos });
    } else if (pos.amount < 0) {
      borrows.push({
        market,
        amount: Math.abs(pos.amount),
        usd: Math.abs(pos.usd),
      });
    }
  }

  supplies.sort((a, b) => b.usd - a.usd);
  borrows.sort((a, b) => b.usd - a.usd);

  const totalSupplyUsd = supplies.reduce((s, p) => s + p.usd, 0);
  const totalBorrowUsd = borrows.reduce((s, p) => s + p.usd, 0);

  const weightedCollateral = supplies.reduce(
    (s, p) => s + p.usd * (collateralFactors[p.market] || 0),
    0
  );
  const healthWithoutTarget = weightedCollateral - totalBorrowUsd;

  if (hasSupply) {
    if (borrows.length === 0) {
      return {
        category: "REDEEM",
        detail: "No borrows, safe to transferAndRedeem",
        targetUsd: target.usd,
        actions: [{ fn: "transferAndRedeem", jToken: targetSymbol }],
      };
    }

    // How much borrow we can safely keep with non-target collateral
    // at the minimum health ratio. If toLiquidate <= 0, safe to redeem.
    const maxSafeBorrows = weightedCollateral / MIN_HEALTH_RATIO;
    const toLiquidate = totalBorrowUsd - maxSafeBorrows;

    if (toLiquidate <= 0) {
      const ratio = totalBorrowUsd > 0
        ? (weightedCollateral / totalBorrowUsd).toFixed(2)
        : "inf";
      return {
        category: "REDEEM",
        detail:
          "Healthy without target collateral " +
          `(health=${ratio}, min=${MIN_HEALTH_RATIO})`,
        targetUsd: target.usd,
        actions: [{ fn: "transferAndRedeem", jToken: targetSymbol }],
      };
    }

    const actions = [];
    let remaining = toLiquidate;

    for (const b of borrows) {
      if (remaining <= 0) break;
      actions.push({
        fn: "liquidate",
        jTokenBorrowed: b.market,
        jTokenCollateral: targetSymbol,
        borrowUsd: b.usd,
        borrowAmount: b.amount,
      });
      remaining -= b.usd;
    }

    actions.push({ fn: "transferAndRedeem", jToken: targetSymbol });

    const canResolve = remaining <= 0;

    return {
      category: canResolve
        ? "LIQUIDATE_BORROWS_THEN_REDEEM"
        : "FLAG_CANNOT_FREE",
      detail: canResolve
        ? `Liquidate borrows to reach health=${MIN_HEALTH_RATIO}, then redeem`
        : `Borrows exceed target collateral value, ` +
          `shortfall=$${Math.abs(remaining).toFixed(2)}`,
      targetUsd: target.usd,
      healthWithoutTarget,
      borrows,
      actions,
    };
  }

  if (hasBorrow) {
    const totalCollateralUsd = totalSupplyUsd;

    if (totalCollateralUsd > 0) {
      const actions = [];
      for (const s of supplies) {
        actions.push({
          fn: "liquidate",
          jTokenBorrowed: targetSymbol,
          jTokenCollateral: s.market,
          collateralUsd: s.usd,
        });
        if (s.usd >= targetUsd) break;
      }

      return {
        category: "LIQUIDATE_BORROW",
        detail:
          `Borrow $${targetUsd.toFixed(2)}, ` +
          `collateral $${totalCollateralUsd.toFixed(2)}`,
        targetUsd: -targetUsd,
        targetAmount: Math.abs(target.amount),
        actions,
        supplies,
      };
    }

    const actions = [];
    actions.push({
      fn: "repayBorrowBehalf",
      jToken: targetSymbol,
      amount: targetUsd,
    });

    return {
      category: "BAD_DEBT",
      detail:
        `Borrow $${targetUsd.toFixed(2)}, ` +
        `collateral $${totalCollateralUsd.toFixed(2)} (bad debt)`,
      targetUsd: -targetUsd,
      targetAmount: Math.abs(target.amount),
      actions,
    };
  }

  return null;
}

async function fetchMarketData(provider, asset) {
  const joetrollerIface = new ethers.utils.Interface(JOETROLLER_ABI);
  const jTokenIface = new ethers.utils.Interface(JTOKEN_ABI);
  const multicall = new ethers.Contract(
    MULTICALL3, MULTICALL_ABI, provider
  );

  // Round 0: market list + oracle
  const round0 = await multicall.callStatic.aggregate3([
    {
      target: JOETROLLER,
      allowFailure: false,
      callData: joetrollerIface.encodeFunctionData("getAllMarkets"),
    },
    {
      target: JOETROLLER,
      allowFailure: false,
      callData: joetrollerIface.encodeFunctionData("oracle"),
    },
  ]);
  const allMarkets = joetrollerIface.decodeFunctionResult(
    "getAllMarkets", round0[0].returnData
  )[0];
  const oracleAddr = joetrollerIface.decodeFunctionResult(
    "oracle", round0[1].returnData
  )[0];

  // Round 1: symbol + collateralFactor + underlying for every market
  const calls = [];
  for (const addr of allMarkets) {
    calls.push(
      {
        target: addr,
        allowFailure: false,
        callData: jTokenIface.encodeFunctionData("symbol"),
      },
      {
        target: JOETROLLER,
        allowFailure: false,
        callData: joetrollerIface.encodeFunctionData("markets", [addr]),
      },
      {
        target: addr,
        allowFailure: true,
        callData: jTokenIface.encodeFunctionData("underlying"),
      },
    );
  }

  const results = await multicall.callStatic.aggregate3(calls);

  const symbolToAddress = {};
  const collateralFactors = {};
  const underlyingAddresses = {};

  for (let i = 0; i < allMarkets.length; i++) {
    const base = i * 3;
    const symbol = jTokenIface.decodeFunctionResult(
      "symbol", results[base].returnData
    )[0];
    const [, cfMantissa] = joetrollerIface.decodeFunctionResult(
      "markets", results[base + 1].returnData
    );
    const underlyingResult = results[base + 2];
    const underlyingAddr = underlyingResult.success
      ? jTokenIface.decodeFunctionResult("underlying", underlyingResult.returnData)[0]
      : null;

    symbolToAddress[symbol] = allMarkets[i];
    underlyingAddresses[symbol] = underlyingAddr;
    collateralFactors[symbol] = parseFloat(
      ethers.utils.formatUnits(cfMantissa, 18)
    );
  }

  // Match --asset against jToken symbols (with or without 'j' prefix)
  const needle = asset.toLowerCase();
  const targetSymbol = Object.keys(symbolToAddress).find((sym) => {
    const s = sym.toLowerCase();
    return s === needle || s === `j${needle}`;
  });

  if (!targetSymbol) {
    const available = Object.keys(symbolToAddress)
      .map((s) => s.slice(1))
      .join(", ");
    throw new Error(
      `Unknown asset "${asset}". Available assets: ${available}`
    );
  }

  const targetAddress = symbolToAddress[targetSymbol];

  console.log(`Target market: ${targetSymbol} (${targetAddress})`);
  console.log(`Oracle: ${oracleAddr}`);
  console.log(
    `Markets: ${Object.keys(symbolToAddress).join(", ")}`
  );
  console.log("\nCollateral factors:");
  for (const [sym, cf] of Object.entries(collateralFactors)) {
    console.log(`  ${sym}: ${cf}`);
  }

  return {
    symbolToAddress,
    collateralFactors,
    underlyingAddresses,
    targetSymbol,
    targetAddress,
  };
}

task("actions", "Classify users and generate action plan for market wind-down")
  .addParam("asset", "Underlying asset symbol, e.g. MIM or JOE", undefined, types.string)
  .setAction(async ({ asset }, hre) => {
    ethers = hre.ethers;
    const provider = ethers.provider;

    const csvPath = path.join(
      __dirname, "..", `${asset.toLowerCase()}-user-positions.csv`
    );
    if (!fs.existsSync(csvPath)) {
      throw new Error(
        `CSV not found: ${csvPath}\n` +
        `Run "npx hardhat positions --asset ${asset}" first.`
      );
    }

    const {
      symbolToAddress,
      collateralFactors,
      underlyingAddresses,
      targetSymbol,
      targetAddress,
    } = await fetchMarketData(provider, asset);

    const { users } = parsePositionsCsv(csvPath);

    const categories = {
      REDEEM: [],
      LIQUIDATE_BORROW: [],
      BAD_DEBT: [],
      LIQUIDATE_BORROWS_THEN_REDEEM: [],
      FLAG_CANNOT_FREE: [],
    };

    for (const user of users) {
      const r = classify(user, targetSymbol, collateralFactors);
      if (!r) continue;
      categories[r.category].push({
        address: user.address,
        ...r,
      });
    }

    // Console summary
    console.log("\n" + "=".repeat(70));
    console.log(`  ${targetSymbol} MARKET DEPRECATION - ACTION PLAN`);
    console.log("=".repeat(70));

    for (const [cat, items] of Object.entries(categories)) {
      if (items.length === 0) continue;
      const total = items.reduce(
        (s, i) => s + Math.abs(i.targetUsd), 0
      );
      console.log(
        `  ${cat}: ${items.length} users, $${total.toFixed(2)}`
      );
    }
    console.log("");

    // Compute per-token funding required for TrustedLiquidator
    // - LIQUIDATE_BORROW: needs target token to repay borrow
    // - BAD_DEBT: needs target token to repay on behalf
    // - LIQUIDATE_BORROWS_THEN_REDEEM: needs OTHER tokens to repay
    //   those borrows (e.g. USDC to repay a USDC borrow)
    const fundingBySymbol = {}; // jToken symbol -> { amount, usd }

    function addFunding(jSymbol, amount, usd) {
      if (!fundingBySymbol[jSymbol]) {
        fundingBySymbol[jSymbol] = { amount: 0, usd: 0 };
      }
      fundingBySymbol[jSymbol].amount += amount;
      fundingBySymbol[jSymbol].usd += usd;
    }

    for (const item of categories.LIQUIDATE_BORROW) {
      addFunding(targetSymbol, item.targetAmount, Math.abs(item.targetUsd));
    }
    for (const item of categories.BAD_DEBT) {
      addFunding(targetSymbol, item.targetAmount, Math.abs(item.targetUsd));
    }
    for (const item of [
      ...categories.LIQUIDATE_BORROWS_THEN_REDEEM,
      ...categories.FLAG_CANNOT_FREE,
    ]) {
      for (const a of item.actions) {
        if (a.fn === "liquidate" && a.borrowAmount) {
          addFunding(a.jTokenBorrowed, a.borrowAmount, a.borrowUsd);
        }
      }
    }

    let totalFundingUsd = 0;

    console.log("=".repeat(70));
    console.log("  FUNDING REQUIRED FOR TRUSTED LIQUIDATOR");
    console.log("=".repeat(70));

    const fundingTokens = [];
    for (const [jSymbol, f] of Object.entries(fundingBySymbol)) {
      const displaySymbol = jSymbol.startsWith("j")
        ? jSymbol.slice(1) : jSymbol;
      console.log(
        `  ${displaySymbol}: ${f.amount.toFixed(6)} (~$${f.usd.toFixed(2)})`
      );
      totalFundingUsd += f.usd;
      fundingTokens.push({
        token: underlyingAddresses[jSymbol],
        symbol: displaySymbol,
        amount: f.amount.toString(),
        amountUsd: f.usd.toFixed(2),
      });
    }

    console.log(`  TOTAL: ~$${totalFundingUsd.toFixed(2)}`);
    console.log(
      "\n  NOTE: Add buffer for interest accrual between snapshot and execution."
    );
    console.log("=".repeat(70));

    // Build Forge-consumable JSON with addresses
    const forgeOutput = {
      targetJToken: targetAddress,
      targetSymbol,
      funding: {
        tokens: fundingTokens,
        totalUsd: totalFundingUsd.toFixed(2),
      },
      transferAndRedeem: [],
      liquidate: [],
      repayBorrowBehalf: [],
    };

    for (const [, items] of Object.entries(categories)) {
      for (const item of items) {
        for (const a of item.actions) {
          if (a.fn === "transferAndRedeem") {
            forgeOutput.transferAndRedeem.push({
              jToken: symbolToAddress[a.jToken],
              user: item.address,
            });
          } else if (a.fn === "liquidate") {
            forgeOutput.liquidate.push({
              jTokenBorrowed: symbolToAddress[a.jTokenBorrowed],
              jTokenCollateral: symbolToAddress[a.jTokenCollateral],
              user: item.address,
            });
          } else if (a.fn === "repayBorrowBehalf") {
            forgeOutput.repayBorrowBehalf.push({
              jToken: symbolToAddress[a.jToken],
              user: item.address,
            });
          }
        }
      }
    }

    const jsonPath = path.join(
      __dirname, "..",
      `${asset.toLowerCase()}-action-plan.json`
    );
    fs.writeFileSync(
      jsonPath, JSON.stringify(forgeOutput, null, 2) + "\n"
    );

    console.log(`\nForge JSON saved to ${jsonPath}`);
    console.log(
      `  ${forgeOutput.transferAndRedeem.length} transferAndRedeem, ` +
      `${forgeOutput.liquidate.length} liquidate, ` +
      `${forgeOutput.repayBorrowBehalf.length} repayBorrowBehalf\n`
    );
  });
