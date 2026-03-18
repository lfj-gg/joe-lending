const { task } = require("hardhat/config");
const { BigNumber } = require("ethers");

const JOETROLLER_ADDRESS = "0xdc13687554205E5b89Ac783db14bb5bba4A1eDaC";
const SECONDS_PER_YEAR = 365.25 * 24 * 60 * 60;

const JOETROLLER_ABI = [
  "function getAllMarkets() view returns (address[])",
  "function markets(address) view returns (bool isListed, uint256 collateralFactorMantissa, uint8 version)",
  "function oracle() view returns (address)",
  "function mintGuardianPaused(address) view returns (bool)",
  "function borrowGuardianPaused(address) view returns (bool)",
  "function supplyCaps(address) view returns (uint256)",
  "function borrowCaps(address) view returns (uint256)",
];

const JTOKEN_ABI = [
  "function symbol() view returns (string)",
  "function name() view returns (string)",
  "function decimals() view returns (uint8)",
  "function exchangeRateStored() view returns (uint256)",
  "function supplyRatePerSecond() view returns (uint256)",
  "function borrowRatePerSecond() view returns (uint256)",
  "function totalSupply() view returns (uint256)",
  "function totalBorrows() view returns (uint256)",
  "function totalReserves() view returns (uint256)",
  "function getCash() view returns (uint256)",
  "function reserveFactorMantissa() view returns (uint256)",
  "function underlying() view returns (address)",
];

const ORACLE_ABI = [
  "function getUnderlyingPrice(address) view returns (uint256)",
];

const ERC20_ABI = [
  "function decimals() view returns (uint8)",
  "function symbol() view returns (string)",
];

function formatUsd(value) {
  if (value >= 1e9) return `$${(value / 1e9).toFixed(2)}B`;
  if (value >= 1e6) return `$${(value / 1e6).toFixed(2)}M`;
  if (value >= 1e3) return `$${(value / 1e3).toFixed(2)}K`;
  return `$${value.toFixed(2)}`;
}

function formatPct(value) {
  return `${value.toFixed(2)}%`;
}

function formatPrice(value) {
  if (value >= 1000) return `$${value.toFixed(2)}`;
  if (value >= 1) return `$${value.toFixed(4)}`;
  return `$${value.toFixed(6)}`;
}

function formatAmount(value, decimals) {
  if (value >= 1e9) return `${(value / 1e9).toFixed(2)}B`;
  if (value >= 1e6) return `${(value / 1e6).toFixed(2)}M`;
  if (value >= 1e3) return `${(value / 1e3).toFixed(2)}K`;
  if (decimals <= 8) return value.toFixed(4);
  return value.toFixed(2);
}

function padRight(str, len) {
  return str.length >= len ? str : str + " ".repeat(len - str.length);
}

function padLeft(str, len) {
  return str.length >= len ? str : " ".repeat(len - str.length) + str;
}

function printTable(headers, rows, alignRight) {
  const colWidths = headers.map((h, i) =>
    Math.max(h.length, ...rows.map((r) => String(r[i]).length))
  );

  const headerLine = headers
    .map((h, i) => (alignRight[i] ? padLeft(h, colWidths[i]) : padRight(h, colWidths[i])))
    .join("  ");
  const separator = colWidths.map((w) => "-".repeat(w)).join("--");

  console.log(headerLine);
  console.log(separator);
  for (const row of rows) {
    const line = row
      .map((cell, i) => {
        const s = String(cell);
        return alignRight[i] ? padLeft(s, colWidths[i]) : padRight(s, colWidths[i]);
      })
      .join("  ");
    console.log(line);
  }
}

// Multicall3 — same address on all EVM chains
const MULTICALL3 = "0xcA11bde05977b3631167028862bE2a173976CA11";

const MULTICALL_ABI = [
  "function aggregate3(tuple(address target, bool allowFailure, bytes callData)[] calls) returns (tuple(bool success, bytes returnData)[])",
];

const JTOKEN_FULL_ABI = [
  "function accrueInterest() returns (uint256)",
  ...JTOKEN_ABI,
];

const NATIVE_SYMBOLS = new Set(["jAVAX"]);

async function fetchMarketData(jTokenAddr, joetroller, provider) {
  const jTokenIface = new ethers.utils.Interface(JTOKEN_FULL_ABI);
  const multicall = new ethers.Contract(MULTICALL3, MULTICALL_ABI, provider);
  const jToken = new ethers.Contract(jTokenAddr, JTOKEN_ABI, provider);

  // Use multicall: accrueInterest first, then read all values in one eth_call
  // so exchangeRate, totalBorrows, totalReserves reflect current block
  const jTokenCalls = [
    "accrueInterest",
    "symbol",
    "decimals",
    "exchangeRateStored",
    "supplyRatePerSecond",
    "borrowRatePerSecond",
    "totalSupply",
    "totalBorrows",
    "totalReserves",
    "getCash",
    "reserveFactorMantissa",
  ].map((fn) => ({
    target: jTokenAddr,
    allowFailure: false,
    callData: jTokenIface.encodeFunctionData(fn),
  }));

  const mcResults = await multicall.callStatic.aggregate3(jTokenCalls);

  // Skip index 0 (accrueInterest), decode the rest
  const decode = (fn, idx) =>
    jTokenIface.decodeFunctionResult(fn, mcResults[idx].returnData)[0];

  const symbol = decode("symbol", 1);
  const jTokenDecimals = decode("decimals", 2);
  const exchangeRateStored = decode("exchangeRateStored", 3);
  const supplyRatePerSecond = decode("supplyRatePerSecond", 4);
  const borrowRatePerSecond = decode("borrowRatePerSecond", 5);
  const totalSupply = decode("totalSupply", 6);
  const totalBorrows = decode("totalBorrows", 7);
  const totalReserves = decode("totalReserves", 8);
  const cash = decode("getCash", 9);
  const reserveFactorMantissa = decode("reserveFactorMantissa", 10);

  let underlyingDecimals = 18;
  let underlyingSymbol = "AVAX";
  if (!NATIVE_SYMBOLS.has(symbol)) {
    const underlyingAddr = await jToken.underlying();
    const underlying = new ethers.Contract(underlyingAddr, ERC20_ABI, provider);
    [underlyingDecimals, underlyingSymbol] = await Promise.all([
      underlying.decimals(),
      underlying.symbol(),
    ]);
  }

  const [
    marketInfo,
    oraclePrice,
    supplyPaused,
    borrowPaused,
    supplyCap,
    borrowCap,
  ] = await Promise.all([
    joetroller.markets(jTokenAddr),
    joetroller.oracle().then((oracleAddr) => {
      const oracle = new ethers.Contract(oracleAddr, ORACLE_ABI, provider);
      return oracle.getUnderlyingPrice(jTokenAddr);
    }),
    joetroller.mintGuardianPaused(jTokenAddr),
    joetroller.borrowGuardianPaused(jTokenAddr),
    joetroller.supplyCaps(jTokenAddr),
    joetroller.borrowCaps(jTokenAddr),
  ]);

  const scale = BigNumber.from(10).pow(underlyingDecimals);
  const mantissa = BigNumber.from(10).pow(18);

  const priceScaled = parseFloat(
    ethers.utils.formatUnits(oraclePrice, 36 - underlyingDecimals)
  );

  const exchangeRateDecimalAdj =
    18 + underlyingDecimals - jTokenDecimals;
  const exchangeRate = parseFloat(
    ethers.utils.formatUnits(exchangeRateStored, exchangeRateDecimalAdj)
  );

  const totalSupplyUnderlying =
    parseFloat(ethers.utils.formatUnits(totalSupply, jTokenDecimals)) *
    exchangeRate;
  const totalBorrowsNum = parseFloat(
    ethers.utils.formatUnits(totalBorrows, underlyingDecimals)
  );
  const totalReservesNum = parseFloat(
    ethers.utils.formatUnits(totalReserves, underlyingDecimals)
  );
  const cashNum = parseFloat(
    ethers.utils.formatUnits(cash, underlyingDecimals)
  );

  const totalSupplyUsd = totalSupplyUnderlying * priceScaled;
  const totalBorrowUsd = totalBorrowsNum * priceScaled;
  const totalReservesUsd = totalReservesNum * priceScaled;

  const utilization =
    cashNum + totalBorrowsNum > 0
      ? (totalBorrowsNum / (cashNum + totalBorrowsNum)) * 100
      : 0;

  const supplyApy =
    parseFloat(ethers.utils.formatUnits(supplyRatePerSecond, 18)) *
    SECONDS_PER_YEAR *
    100;
  const borrowApy =
    parseFloat(ethers.utils.formatUnits(borrowRatePerSecond, 18)) *
    SECONDS_PER_YEAR *
    100;

  const reserveFactor =
    parseFloat(ethers.utils.formatUnits(reserveFactorMantissa, 18)) * 100;
  const collateralFactor =
    parseFloat(
      ethers.utils.formatUnits(marketInfo.collateralFactorMantissa, 18)
    ) * 100;

  const supplyCapNum = parseFloat(
    ethers.utils.formatUnits(supplyCap, underlyingDecimals)
  );
  const borrowCapNum = parseFloat(
    ethers.utils.formatUnits(borrowCap, underlyingDecimals)
  );

  return {
    symbol,
    underlyingSymbol,
    underlyingDecimals,
    isListed: marketInfo.isListed,
    priceScaled,
    totalSupplyUnderlying,
    totalSupplyUsd,
    totalBorrowsNum,
    totalBorrowUsd,
    totalReservesNum,
    totalReservesUsd,
    cashNum,
    utilization,
    supplyApy,
    borrowApy,
    reserveFactor,
    collateralFactor,
    supplyPaused,
    borrowPaused,
    supplyCapNum,
    borrowCapNum,
  };
}

task("dashboard", "Display Banker Joe lending dashboard").setAction(
  async (_, hre) => {
    const { ethers } = hre;
    const provider = ethers.provider;

    console.log("\nFetching Banker Joe market data...\n");

    const joetroller = new ethers.Contract(
      JOETROLLER_ADDRESS,
      JOETROLLER_ABI,
      provider
    );

    const allMarkets = await joetroller.getAllMarkets();
    console.log(`Found ${allMarkets.length} markets\n`);

    const markets = await Promise.all(
      allMarkets.map((addr) => fetchMarketData(addr, joetroller, provider))
    );

    const listed = markets.filter((m) => m.isListed);
    listed.sort((a, b) => b.totalSupplyUsd - a.totalSupplyUsd);

    const totalProtocolSupply = listed.reduce(
      (sum, m) => sum + m.totalSupplyUsd, 0
    );
    const totalProtocolBorrow = listed.reduce(
      (sum, m) => sum + m.totalBorrowUsd, 0
    );
    const totalProtocolReserves = listed.reduce(
      (sum, m) => sum + m.totalReservesUsd, 0
    );

    console.log("=".repeat(70));
    console.log("  BANKER JOE - LENDING DASHBOARD");
    console.log("=".repeat(70));
    console.log(
      `  Total Supply:   ${formatUsd(totalProtocolSupply)}`
    );
    console.log(
      `  Total Borrow:   ${formatUsd(totalProtocolBorrow)}`
    );
    console.log(
      `  Total Reserves: ${formatUsd(totalProtocolReserves)}`
    );
    console.log(
      `  Utilization:    ${formatPct(
        totalProtocolBorrow / totalProtocolSupply * 100
      )}`
    );
    console.log("=".repeat(70));

    // Market Overview Table
    console.log("\n--- MARKET OVERVIEW ---\n");

    const overviewHeaders = [
      "Market",
      "Underlying",
      "Price",
      "Supply (USD)",
      "Borrow (USD)",
      "Util %",
      "Supply APY",
      "Borrow APY",
    ];
    const overviewAlign = [false, false, true, true, true, true, true, true];
    const overviewRows = listed.map((m) => [
      m.symbol,
      m.underlyingSymbol,
      formatPrice(m.priceScaled),
      formatUsd(m.totalSupplyUsd),
      formatUsd(m.totalBorrowUsd),
      formatPct(m.utilization),
      formatPct(m.supplyApy),
      formatPct(m.borrowApy),
    ]);
    printTable(overviewHeaders, overviewRows, overviewAlign);

    // Market Details Table
    console.log("\n--- MARKET DETAILS ---\n");

    const detailHeaders = [
      "Market",
      "Reserves (USD)",
      "CF %",
      "RF %",
      "Supply Cap",
      "Borrow Cap",
      "S.Paused",
      "B.Paused",
    ];
    const detailAlign = [false, true, true, true, true, true, false, false];
    const detailRows = listed.map((m) => [
      m.symbol,
      formatUsd(m.totalReservesUsd),
      formatPct(m.collateralFactor),
      formatPct(m.reserveFactor),
      m.supplyCapNum === 0
        ? "unlimited"
        : formatAmount(m.supplyCapNum, m.underlyingDecimals),
      m.borrowCapNum === 0
        ? "unlimited"
        : formatAmount(m.borrowCapNum, m.underlyingDecimals),
      m.supplyPaused ? "YES" : "no",
      m.borrowPaused ? "YES" : "no",
    ]);
    printTable(detailHeaders, detailRows, detailAlign);

    // Raw amounts table
    console.log("\n--- UNDERLYING AMOUNTS ---\n");

    const amountHeaders = [
      "Market",
      "Total Supply",
      "Total Borrow",
      "Reserves",
      "Cash",
    ];
    const amountAlign = [false, true, true, true, true];
    const amountRows = listed.map((m) => [
      m.symbol,
      formatAmount(m.totalSupplyUnderlying, m.underlyingDecimals),
      formatAmount(m.totalBorrowsNum, m.underlyingDecimals),
      formatAmount(m.totalReservesNum, m.underlyingDecimals),
      formatAmount(m.cashNum, m.underlyingDecimals),
    ]);
    printTable(amountHeaders, amountRows, amountAlign);

    console.log("");
  }
);
