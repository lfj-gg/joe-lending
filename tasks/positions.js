const { task, types } = require("hardhat/config");
const https = require("https");
const fs = require("fs");
const path = require("path");

const JOETROLLER_ADDRESS = "0xdc13687554205E5b89Ac783db14bb5bba4A1eDaC";
const MULTICALL3 = "0xcA11bde05977b3631167028862bE2a173976CA11";

const SUBGRAPH_URL =
  "https://gateway-arbitrum.network.thegraph.com/api/" +
  `${process.env.GRAPH_API_KEY}/subgraphs/id/` +
  "JB5EdQqbddMjawMLYe3C5ifmhN9WKYvLdgAKoUy1CyYy";

const JOETROLLER_ABI = [
  "function getAllMarkets() view returns (address[])",
  "function oracle() view returns (address)",
];

const ORACLE_ABI = [
  "function getUnderlyingPrice(address) view returns (uint256)",
];

const JTOKEN_ABI = [
  "function accrueInterest() returns (uint256)",
  "function symbol() view returns (string)",
  "function decimals() view returns (uint8)",
  "function exchangeRateStored() view returns (uint256)",
  "function balanceOf(address) view returns (uint256)",
  "function borrowBalanceStored(address) view returns (uint256)",
  "function underlying() view returns (address)",
  "function totalSupply() view returns (uint256)",
  "function totalBorrows() view returns (uint256)",
];

const ERC20_ABI = ["function decimals() view returns (uint8)"];

const MULTICALL_ABI = [
  "function aggregate3(tuple(address target, bool allowFailure, bytes callData)[] calls) returns (tuple(bool success, bytes returnData)[])",
];

// jAVAX wraps native AVAX — no underlying() call needed
const NATIVE_SYMBOLS = new Set(["jAVAX"]);

const BATCH_SIZE = 200;

function graphqlPost(url, query) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({ query });
    const parsed = new URL(url);
    const options = {
      hostname: parsed.hostname,
      path: parsed.pathname,
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Content-Length": Buffer.byteLength(body),
      },
    };

    const req = https.request(options, (res) => {
      let data = "";
      res.on("data", (chunk) => { data += chunk; });
      res.on("end", () => {
        try {
          const result = JSON.parse(data);
          if (result.errors) {
            reject(new Error(result.errors[0].message));
          }
          resolve(result.data);
        } catch (e) {
          reject(new Error(`JSON parse error: ${data.slice(0, 300)}`));
        }
      });
    });

    req.on("error", reject);
    req.write(body);
    req.end();
  });
}

async function fetchUsersFromSubgraph(marketAddress) {
  const marketId = marketAddress.toLowerCase();
  const addresses = new Set();
  let lastId = "";
  const pageSize = 1000;

  while (true) {
    const query = `{
      accountJTokens(
        first: ${pageSize}
        where: {
          or: [
            { market: "${marketId}", jTokenBalance_gt: "0"${lastId ? `, id_gt: "${lastId}"` : ""} }
            { market: "${marketId}", storedBorrowBalance_gt: "0"${lastId ? `, id_gt: "${lastId}"` : ""} }
          ]
        }
        orderBy: id
        orderDirection: asc
      ) {
        id
        account { id }
      }
    }`;

    const data = await graphqlPost(SUBGRAPH_URL, query);
    const items = data.accountJTokens;
    for (const item of items) {
      addresses.add(item.account.id);
    }

    if (items.length < pageSize) break;
    lastId = items[items.length - 1].id;
  }

  return Array.from(addresses);
}

function formatExact(bn, decimals) {
  if (bn.isZero()) return "0";
  const neg = bn.isNegative();
  const abs = neg ? bn.mul(-1) : bn;
  const str = abs.toString().padStart(decimals + 1, "0");
  const intPart = str.slice(0, str.length - decimals);
  const decPart = str.slice(str.length - decimals).replace(/0+$/, "");
  const num = decPart ? `${intPart}.${decPart}` : intPart;
  return neg ? `-${num}` : num;
}

function formatUsdExact(bn, BigNumber) {
  if (bn.isZero()) return "0";
  const neg = bn.isNegative();
  const abs = neg ? bn.mul(-1) : bn;
  // Divide by 1e16 to get cents (2 decimal places from 18-decimal value)
  const cents = abs.div(BigNumber.from(10).pow(16));
  const str = cents.toString().padStart(3, "0");
  const intPart = str.slice(0, str.length - 2);
  const decPart = str.slice(str.length - 2);
  const num = `${intPart}.${decPart}`;
  return neg ? `-${num}` : num;
}

task("positions", "Fetch all market positions for users of a given asset")
  .addParam("asset", "Underlying asset symbol, e.g. MIM or JOE", undefined, types.string)
  .setAction(async ({ asset }, hre) => {
    const { ethers } = hre;
    const { BigNumber } = ethers;
    const provider = ethers.provider;

    if (!process.env.GRAPH_API_KEY) {
      throw new Error("GRAPH_API_KEY required in .env");
    }

    // Set up interfaces, multicall contract, and constants — used throughout
    const jTokenIface = new ethers.utils.Interface(JTOKEN_ABI);
    const oracleIface = new ethers.utils.Interface(ORACLE_ABI);
    const erc20Iface = new ethers.utils.Interface(ERC20_ABI);
    const joetrollerIface = new ethers.utils.Interface(JOETROLLER_ABI);
    const multicall = new ethers.Contract(MULTICALL3, MULTICALL_ABI, provider);
    const e18 = BigNumber.from(10).pow(18);

    // Round 0: market list + oracle address in a single multicall
    const round0 = await multicall.callStatic.aggregate3([
      {
        target: JOETROLLER_ADDRESS,
        allowFailure: false,
        callData: joetrollerIface.encodeFunctionData("getAllMarkets"),
      },
      {
        target: JOETROLLER_ADDRESS,
        allowFailure: false,
        callData: joetrollerIface.encodeFunctionData("oracle"),
      },
    ]);
    const allMarketAddrs = joetrollerIface.decodeFunctionResult(
      "getAllMarkets", round0[0].returnData
    )[0];
    const oracleAddr = joetrollerIface.decodeFunctionResult(
      "oracle", round0[1].returnData
    )[0];

    console.log(`\nFetching metadata for ${allMarketAddrs.length} markets...`);

    // Round 1: symbol + decimals + underlying (allowFailure for native wrappers) + oracle price
    // for every market — 4 calls per market, one batch
    const round1Calls = [];
    for (const addr of allMarketAddrs) {
      round1Calls.push(
        { target: addr, allowFailure: false, callData: jTokenIface.encodeFunctionData("symbol") },
        { target: addr, allowFailure: false, callData: jTokenIface.encodeFunctionData("decimals") },
        { target: addr, allowFailure: true,  callData: jTokenIface.encodeFunctionData("underlying") },
        {
          target: oracleAddr,
          allowFailure: false,
          callData: oracleIface.encodeFunctionData("getUnderlyingPrice", [addr]),
        },
      );
    }
    const round1Results = await multicall.callStatic.aggregate3(round1Calls);

    const marketData = allMarketAddrs.map((addr, i) => {
      const base = i * 4;
      const symbol = jTokenIface.decodeFunctionResult(
        "symbol", round1Results[base].returnData
      )[0];
      const jDecimals = jTokenIface.decodeFunctionResult(
        "decimals", round1Results[base + 1].returnData
      )[0];
      const underlyingResult = round1Results[base + 2];
      const underlyingAddr = underlyingResult.success
        ? jTokenIface.decodeFunctionResult("underlying", underlyingResult.returnData)[0]
        : null;
      const price = oracleIface.decodeFunctionResult(
        "getUnderlyingPrice", round1Results[base + 3].returnData
      )[0];
      return { address: addr, symbol, jDecimals, underlyingAddr, price };
    });

    // Round 2: underlying token decimals for all non-native markets in one batch
    const nonNativeMarkets = marketData.filter((m) => m.underlyingAddr !== null);
    const round2Results = nonNativeMarkets.length > 0
      ? await multicall.callStatic.aggregate3(
          nonNativeMarkets.map((m) => ({
            target: m.underlyingAddr,
            allowFailure: false,
            callData: erc20Iface.encodeFunctionData("decimals"),
          }))
        )
      : [];

    const underlyingDecimalsMap = new Map(
      nonNativeMarkets.map((m, i) => [
        m.address,
        erc20Iface.decodeFunctionResult("decimals", round2Results[i].returnData)[0],
      ])
    );

    const markets = marketData.map((m) => ({
      address: m.address,
      symbol: m.symbol,
      jDecimals: m.jDecimals,
      underlyingDecimals: underlyingDecimalsMap.get(m.address) ?? 18,
      price: m.price,
    }));

    // Match --asset against jToken symbols (accept with or without leading 'j')
    const needle = asset.toLowerCase();
    const targetMarket = markets.find((m) => {
      const sym = m.symbol.toLowerCase();
      return sym === needle || sym === `j${needle}`;
    });

    if (!targetMarket) {
      const available = markets.map((m) => m.symbol.slice(1)).join(", ");
      throw new Error(
        `Unknown asset "${asset}". Available assets: ${available}`
      );
    }

    console.log(
      `Target market: ${targetMarket.symbol} (${targetMarket.address})`
    );
    console.log(
      `All markets: ${markets.map((m) => m.symbol).join(", ")}\n`
    );

    // Fetch users who have ever interacted with the target market via subgraph
    console.log("Fetching user list from subgraph...");
    const users = await fetchUsersFromSubgraph(targetMarket.address);
    console.log(`  Found ${users.length} addresses\n`);

    // For each market, multicall accrueInterest + exchangeRate + balanceOf + borrowBalanceStored
    // per user. positions[marketIdx] = Map<address, { supply, borrow }> in underlying raw units.
    const positions = markets.map(() => new Map());
    // Track raw jToken supply and borrow sums for the target market sanity check
    let sumJTokenBalance = BigNumber.from(0);
    let sumBorrowBalance = BigNumber.from(0);

    for (let mi = 0; mi < markets.length; mi++) {
      const market = markets[mi];
      const isTarget = market.address === targetMarket.address;
      process.stdout.write(`  ${market.symbol}...`);

      for (let i = 0; i < users.length; i += BATCH_SIZE) {
        const batch = users.slice(i, i + BATCH_SIZE);

        const calls = [
          {
            target: market.address,
            allowFailure: false,
            callData: jTokenIface.encodeFunctionData("accrueInterest"),
          },
          {
            target: market.address,
            allowFailure: false,
            callData: jTokenIface.encodeFunctionData("exchangeRateStored"),
          },
        ];

        for (const addr of batch) {
          calls.push({
            target: market.address,
            allowFailure: false,
            callData: jTokenIface.encodeFunctionData("balanceOf", [addr]),
          });
          calls.push({
            target: market.address,
            allowFailure: false,
            callData: jTokenIface.encodeFunctionData("borrowBalanceStored", [addr]),
          });
        }

        const results = await multicall.callStatic.aggregate3(calls);
        const decode = (fn, idx) =>
          jTokenIface.decodeFunctionResult(fn, results[idx].returnData)[0];

        const exchangeRate = decode("exchangeRateStored", 1);

        for (let j = 0; j < batch.length; j++) {
          const jBalance = decode("balanceOf", 2 + j * 2);
          const borrowBal = decode("borrowBalanceStored", 2 + j * 2 + 1);

          if (isTarget) {
            sumJTokenBalance = sumJTokenBalance.add(jBalance);
            sumBorrowBalance = sumBorrowBalance.add(borrowBal);
          }

          if (jBalance.gt(0) || borrowBal.gt(0)) {
            const supply = jBalance.gt(0)
              ? jBalance.mul(exchangeRate).div(e18)
              : BigNumber.from(0);
            positions[mi].set(batch[j], { supply, borrow: borrowBal });
          }
        }
      }

      console.log(` ${positions[mi].size} positions`);
    }

    const targetIdx = markets.findIndex((m) => m.address === targetMarket.address);

    // Sanity check: compare our sums against on-chain totalSupply / totalBorrows
    // Both are read after accrueInterest in the same eth_call context
    const checkCalls = [
      {
        target: targetMarket.address,
        allowFailure: false,
        callData: jTokenIface.encodeFunctionData("accrueInterest"),
      },
      {
        target: targetMarket.address,
        allowFailure: false,
        callData: jTokenIface.encodeFunctionData("totalSupply"),
      },
      {
        target: targetMarket.address,
        allowFailure: false,
        callData: jTokenIface.encodeFunctionData("totalBorrows"),
      },
    ];
    const checkResults = await multicall.callStatic.aggregate3(checkCalls);
    const onChainTotalSupply = jTokenIface.decodeFunctionResult(
      "totalSupply", checkResults[1].returnData
    )[0];
    const onChainTotalBorrows = jTokenIface.decodeFunctionResult(
      "totalBorrows", checkResults[2].returnData
    )[0];

    const supplyMatch = sumJTokenBalance.eq(onChainTotalSupply);
    // Borrow rounding: borrowBalanceStored does per-user integer division,
    // losing up to 1 wei per user. sum < totalBorrows is expected dust.
    const borrowDiff = onChainTotalBorrows.sub(sumBorrowBalance);
    const borrowerCount = BigNumber.from(
      [...positions[targetIdx]].filter(([, p]) => p.borrow.gt(0)).length
    );
    const borrowMatch = borrowDiff.gte(0) && borrowDiff.lte(borrowerCount);

    console.log(`\n${"=".repeat(60)}`);
    console.log(`  SANITY CHECK — ${targetMarket.symbol}`);
    console.log("=".repeat(60));
    console.log(`  jToken supply:  ${supplyMatch ? "PASS" : "FAIL"}`);
    console.log(`    sum(balanceOf):  ${sumJTokenBalance.toString()}`);
    console.log(`    totalSupply():   ${onChainTotalSupply.toString()}`);
    console.log(`  Borrows:        ${borrowMatch ? "PASS" : "FAIL (missing users?)"}`);
    console.log(`    sum(borrowBal):  ${sumBorrowBalance.toString()}`);
    console.log(`    totalBorrows():  ${onChainTotalBorrows.toString()}`);
    console.log(`    diff:            ${borrowDiff.toString()} (max rounding: ${borrowerCount.toString()})`);
    console.log("=".repeat(60));

    if (!supplyMatch || !borrowMatch) {
      console.log(
        "\n  WARNING: Mismatch detected — some users may be missing from the subgraph.\n"
      );
    }

    // Keep only users with a non-zero position in the target market
    const activeUsers = users.filter((u) => positions[targetIdx].has(u));

    console.log(`\n${activeUsers.length} users with active positions`);

    // Build CSV: address, per-market (amount + USD), total USD
    // Positive = supplied, negative = borrowed (net per market)
    const headerCols = ["address"];
    for (const m of markets) {
      headerCols.push(`${m.symbol} (amount)`, `${m.symbol} (USD)`);
    }
    headerCols.push("TOTAL (USD)");

    const csvRows = [headerCols.join(",")];

    for (const user of activeUsers) {
      const cells = [user];
      let totalUsd = BigNumber.from(0);

      for (let mi = 0; mi < markets.length; mi++) {
        const market = markets[mi];
        const pos = positions[mi].get(user);

        if (!pos) {
          cells.push("0", "0");
          continue;
        }

        const net = pos.supply.sub(pos.borrow);
        cells.push(formatExact(net, market.underlyingDecimals));

        const valueRaw = net.mul(market.price).div(e18);
        cells.push(formatUsdExact(valueRaw, BigNumber));
        totalUsd = totalUsd.add(valueRaw);
      }

      cells.push(formatUsdExact(totalUsd, BigNumber));
      csvRows.push(cells.join(","));
    }

    const outFile = `${asset.toLowerCase()}-user-positions.csv`;
    const outPath = path.join(__dirname, "..", outFile);
    fs.writeFileSync(outPath, csvRows.join("\n") + "\n");

    console.log(`\nSaved to ${outPath}`);
    console.log(`  ${activeUsers.length} users x ${markets.length} markets\n`);
  });
