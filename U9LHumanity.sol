// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
  U9L Humanity Token (full contract)
  - ERC20 base (OpenZeppelin)
  - Auto-liquidity (swap & add)
  - Multi-fee distribution (liquidity, treasury, burn, UBI, BTC stab, carbon, AI)
  - UBI distribution + claim
  - BTC price feed (Chainlink) for governance/stabilization
  - AI governance (momentum-based fee adjustments)
  - _update override to integrate logic into OpenZeppelin ERC20 transfer flow
*/

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

interface IDEXRouter {
    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface IUniswapV2Factory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

contract U9LHumanity is ERC20, ERC20Permit, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ================== CONSTANTS ==================
    uint256 public constant MAX_SUPPLY = 1_000_000_000 * 1e18;
    uint256 public constant INITIAL_MINT = 100_000_000 * 1e18;
    uint256 public constant BTC_TARGET_PRICE = 50_000 * 1e8; // Chainlink has 8 decimals for BTC/USD
    uint256 public constant UBI_DISTRIBUTION_CYCLE = 1 days;

    // ================== ECONOMIC PARAMETERS ==================
    struct EconomicParams {
        uint256 liquidityFee;        // basis points out of 1000 (e.g., 300 => 3%)
        uint256 treasuryFee;
        uint256 burnFee;
        uint256 ubiFee;
        uint256 btcStabilizationFee;
        uint256 carbonOffsetFee;
        uint256 aiReserveFee;
        uint256 totalFee;
    }
    EconomicParams public economicParams;

    // ================== STATE VARIABLES ==================
    IDEXRouter public immutable router;
    IUniswapV2Factory public immutable factory;
    AggregatorV3Interface public immutable btcPriceFeed;
    address public immutable WETH;
    address public immutable treasuryWallet;
    address public immutable carbonOffsetWallet;

    uint256 public btcPriceUpdateThreshold = 1 hours;
    uint256 public lastBTCPrice;
    uint256 public lastBTCTimestamp;
    uint256 public stabilizationReserve; // tokens reserved for stabilization and liquidity
    uint256 public rewardsPool;          // UBI / reward pool
    uint256 public ubiLastDistributed;
    uint256 public totalUBIDistributed;

    uint256 public swapThreshold = 50_000 * 1e18;
    uint256 public lastLiquifyTimestamp;
    bool public liquidityLocked;
    address public liquidityPool;

    int256 public priceMomentum;
    uint256 public lastAICheck;
    bool public tradingEnabled;
    bool private inSwap;

    mapping(address => bool) public isExcludedFromFees;
    mapping(address => uint256) public holderRewards;
    mapping(address => uint256) public lastHolderBalance;
    mapping(address => uint256) public ubiClaims;

    uint256 public ubiPerHolder = 100 * 1e18;   // example: 100 U9L per distribution
    uint256 public minHoldForUBI = 1000 * 1e18; // requires holding ≥1000 U9L to claim

    // ================== EVENTS ==================
    event UBIClaimed(address indexed holder, uint256 amount);
    event AutoLiquify(uint256 tokensSwapped, uint256 ethReceived, uint256 liquidityAdded);
    event CarbonOffset(uint256 amount);
    event BTCStabilization(uint256 btcPrice, uint256 amount, bool isMint);
    event AIGovernanceAction(string action, uint256 value);

    // ================== MODIFIERS ==================
    modifier lockTheSwap() {
        require(!inSwap, "Swap in progress");
        inSwap = true;
        _;
        inSwap = false;
    }

    // ================== CONSTRUCTOR ==================
    constructor(
    address _router,
    address _factory,
    address _btcPriceFeed,
    address _weth,
    address _treasuryWallet,
    address _carbonOffsetWallet
) ERC20("U9L Humanity Token", "U9L") ERC20Permit("U9L Humanity Token") Ownable(msg.sender) {
    // <-- All assignments MUST be here -->
    router = IDEXRouter(_router);
    factory = IUniswapV2Factory(_factory);
    btcPriceFeed = AggregatorV3Interface(_btcPriceFeed);
    WETH = _weth;
    treasuryWallet = _treasuryWallet;
    carbonOffsetWallet = _carbonOffsetWallet;

    economicParams = EconomicParams({
        liquidityFee: 300,
        treasuryFee: 200,
        burnFee: 100,
        ubiFee: 200,
        btcStabilizationFee: 200,
        carbonOffsetFee: 50,
        aiReserveFee: 50,
        totalFee: 1100
    });

    _mint(treasuryWallet, INITIAL_MINT);
    isExcludedFromFees[address(this)] = true;
    isExcludedFromFees[treasuryWallet] = true;
    isExcludedFromFees[carbonOffsetWallet] = true;

    (, int256 btcPrice, , , ) = btcPriceFeed.latestRoundData();
    lastBTCPrice = uint256(btcPrice);
    lastBTCTimestamp = block.timestamp;
}

    // ================== INTERNAL TRANSFER HOOK (_update) ==================
    // We override _update (OpenZeppelin ERC20 internal hook) so mint/burn still work,
    // and to integrate fees, auto-liquify, UBI and AI governance.
    function _update(
        address from,
        address to,
        uint256 value
    ) internal virtual override {
        // Allow minting/burning (from==0 or to==0) regardless of tradingEnabled.
        // For normal transfers, require tradingEnabled.
        if (from != address(0) && to != address(0)) {
            require(tradingEnabled, "Trading not enabled");
        }

        // Apply fees only on normal transfers (not mint/burn) and only if not excluded
        uint256 transferAmount = value;
        if (from != address(0) && to != address(0) && !isExcludedFromFees[from] && !isExcludedFromFees[to]) {
            uint256 fees = (value * economicParams.totalFee) / 1000; // totalFee is in per mille (‰)
            transferAmount = value - fees;
            _distributeFees(from, fees);
        }

        // Perform the token movement / mint / burn using base implementation
        super._update(from, to, transferAmount);

        // Auto-liquify and other periodic actions only for normal transfers and not contract internal ops
        if (
            from != address(0) &&
            to != address(0) &&
            !inSwap &&
            from != address(this) &&
            to != address(this) &&
            !liquidityLocked &&
            balanceOf(address(this)) >= swapThreshold &&
            block.timestamp > lastLiquifyTimestamp + 6 hours
        ) {
            lastLiquifyTimestamp = block.timestamp;
            _autoLiquify();
        }

        // UBI distribution cycle
        if (block.timestamp > ubiLastDistributed + UBI_DISTRIBUTION_CYCLE) {
            _distributeUBI();
        }

        // AI governance check
        if (block.timestamp > lastAICheck + 1 hours) {
            _runAIGovernance();
        }

        // Update holder tracking for rewards (only for normal addresses)
        if (from != address(0)) {
            lastHolderBalance[from] = balanceOf(from);
            _updateRewards(from);
        }
        if (to != address(0)) {
            lastHolderBalance[to] = balanceOf(to);
        }
    }

    // ================== FEE DISTRIBUTION ==================
    function _distributeFees(address sender, uint256 fees) internal {
        EconomicParams memory p = economicParams;

        uint256 liquidityAmount = (fees * p.liquidityFee) / p.totalFee;
        uint256 treasuryAmount = (fees * p.treasuryFee) / p.totalFee;
        uint256 burnAmount = (fees * p.burnFee) / p.totalFee;
        uint256 ubiAmount = (fees * p.ubiFee) / p.totalFee;
        uint256 btcStabAmount = (fees * p.btcStabilizationFee) / p.totalFee;
        uint256 carbonAmount = (fees * p.carbonOffsetFee) / p.totalFee;
        uint256 aiAmount = (fees * p.aiReserveFee) / p.totalFee;

        if (liquidityAmount > 0) {
            super._update(sender, address(this), liquidityAmount);
            stabilizationReserve += liquidityAmount;
        }
        if (treasuryAmount > 0) {
            super._update(sender, treasuryWallet, treasuryAmount);
        }
        if (burnAmount > 0) {
            super._update(sender, address(0), burnAmount); // burn
        }
        if (ubiAmount > 0) {
            // keep UBI portion in rewardsPool (held in contract supply)
            rewardsPool += ubiAmount;
            super._update(sender, address(this), ubiAmount);
        }
        if (btcStabAmount > 0) {
            stabilizationReserve += btcStabAmount;
            super._update(sender, address(this), btcStabAmount);
        }
        if (carbonAmount > 0) {
            super._update(sender, carbonOffsetWallet, carbonAmount);
            emit CarbonOffset(carbonAmount);
        }
        if (aiAmount > 0) {
            stabilizationReserve += aiAmount;
            super._update(sender, address(this), aiAmount);
        }
    }

    // ================== AUTO-LIQUIDITY ==================
    function _autoLiquify() internal lockTheSwap {
        uint256 contractBalance = balanceOf(address(this));
        if (contractBalance == 0) return;

        uint256 tokensToSwap = contractBalance / 2;
        uint256 initialETH = address(this).balance;

        if (liquidityPool == address(0)) {
            liquidityPool = factory.createPair(address(this), WETH);
            isExcludedFromFees[liquidityPool] = true;
        }

        _swapTokensForETH(tokensToSwap);

        uint256 ethReceived = address(this).balance - initialETH;
        if (ethReceived > 0) {
            uint256 tokensForLiquidity = contractBalance - tokensToSwap;
            _addLiquidity(tokensForLiquidity, ethReceived);
            emit AutoLiquify(tokensToSwap, ethReceived, ethReceived);
        }
    }

    function _swapTokensForETH(uint256 tokenAmount) internal {
    address[] memory path = new address[](2);  // ✅ Declare and initialize
    path[0] = address(this);                   // ✅ Fix octal issue
    path[1] = WETH;

    _approve(address(this), address(router), tokenAmount);

    router.swapExactTokensForETHSupportingFeeOnTransferTokens(
        tokenAmount,
        0,
        path,
        address(this),
        block.timestamp + 300
    );
}

    function _addLiquidity(uint256 tokenAmount, uint256 ethAmount) internal {
        _approve(address(this), address(router), tokenAmount);

        router.addLiquidityETH{value: ethAmount}(
            address(this),
            tokenAmount,
            0,
            0,
            address(this),
            block.timestamp + 300
        );
    }

    // ================== BTC PEG STABILIZATION ==================
    // Manual sync callable by anyone to trigger a stabilization check (owner can call too)
    function _checkBTCPeg() internal {
        (, int256 currentBTCPriceInt, , uint256 updatedAt, ) = btcPriceFeed.latestRoundData();
        require(block.timestamp - updatedAt < btcPriceUpdateThreshold, "Stale BTC price");

        uint256 currentPrice = uint256(currentBTCPriceInt);

        if (lastBTCPrice > 0 &&
            (currentPrice > (lastBTCPrice * 105) / 100 ||
             currentPrice < (lastBTCPrice * 95) / 100)) {

            uint256 targetSupply = (currentPrice * MAX_SUPPLY) / BTC_TARGET_PRICE;

            if (targetSupply > totalSupply()) {
                uint256 mintAmount = targetSupply - totalSupply();
                if (stabilizationReserve >= mintAmount) {
                    stabilizationReserve -= mintAmount;
                    _mint(address(this), mintAmount);
                    emit BTCStabilization(currentPrice, mintAmount, true);
                }
            } else if (targetSupply < totalSupply()) {
                uint256 burnAmount = totalSupply() - targetSupply;
                if (balanceOf(address(this)) >= burnAmount) {
                    _burn(address(this), burnAmount);
                    emit BTCStabilization(currentPrice, burnAmount, false);
                }
            }

            lastBTCPrice = currentPrice;
            lastBTCTimestamp = block.timestamp;
        }
    }

    // Exposed manual sync
    function manualSync() external {
        _checkBTCPeg();
    }

    // ================== UBI DISTRIBUTION ==================
    function _distributeUBI() internal {
        if (rewardsPool == 0) return;

        uint256 totalUBI = (totalSupply() * ubiPerHolder) / (1000 * 1e18);
        if (totalUBI > rewardsPool / 5) totalUBI = rewardsPool / 5;

        if (totalUBI > 0 && rewardsPool >= totalUBI) {
            rewardsPool -= totalUBI;
            totalUBIDistributed += totalUBI;
            ubiLastDistributed = block.timestamp;
            emit AIGovernanceAction("UBI Distribution", totalUBI);
            // Note: actual per-holder distribution requires iteration (gas heavy).
            // For now, rewardsPool is reduced; holders call claimUBI() to mint themselves if eligible.
        }
    }

    function claimUBI() external {
        require(balanceOf(msg.sender) >= minHoldForUBI, "Insufficient balance to claim UBI");
        require(block.timestamp > ubiLastDistributed, "No UBI available right now");

        uint256 ubiAmount = ubiPerHolder;
        if (rewardsPool < ubiAmount) ubiAmount = rewardsPool;
        require(ubiAmount > 0, "No UBI available");

        rewardsPool -= ubiAmount;
        _mint(msg.sender, ubiAmount);
        ubiClaims[msg.sender] += ubiAmount;
        emit UBIClaimed(msg.sender, ubiAmount);
    }

    // ================== AI GOVERNANCE ==================
    function _runAIGovernance() internal {
        (, int256 currentBTCPriceInt, , , ) = btcPriceFeed.latestRoundData();
        uint256 currentPrice = uint256(currentBTCPriceInt);

        if (lastBTCPrice > 0) {
            int256 change = int256(currentPrice) - int256(lastBTCPrice);
            // momentum scaled to +/- 100-ish
            priceMomentum = (priceMomentum * 9) / 10 + (change * 100 / int256(lastBTCPrice));

            if (priceMomentum > 50) economicParams.btcStabilizationFee = 300;
            else if (priceMomentum < -50) economicParams.btcStabilizationFee = 100;
            else economicParams.btcStabilizationFee = 200;

            economicParams.totalFee =
                economicParams.liquidityFee +
                economicParams.treasuryFee +
                economicParams.burnFee +
                economicParams.ubiFee +
                economicParams.btcStabilizationFee +
                economicParams.carbonOffsetFee +
                economicParams.aiReserveFee;
        }

        lastAICheck = block.timestamp;
    }

    // ================== REWARDS (simple bookkeeping) ==================
    function _updateRewards(address holder) internal {
        if (holder == address(0) || isExcludedFromFees[holder]) return;
        uint256 holderBalance = balanceOf(holder);
        uint256 balanceChange = 0;
        if (holderBalance > lastHolderBalance[holder]) balanceChange = holderBalance - lastHolderBalance[holder];
        if (balanceChange > 0 && totalSupply() > 0) {
            holderRewards[holder] += (balanceChange * rewardsPool) / totalSupply();
        }
        lastHolderBalance[holder] = holderBalance;
    }

    function claimRewards() external {
        uint256 reward = holderRewards[msg.sender];
        require(reward > 0, "No rewards");
        holderRewards[msg.sender] = 0;
        // transfer from contract's balance if sufficient, otherwise mint
        if (balanceOf(address(this)) >= reward) {
            _transfer(address(this), msg.sender, reward);
        } else {
            _mint(msg.sender, reward);
        }
    }

    // ================== OWNER FUNCTIONS ==================
    function setTradingEnabled(bool enabled) external onlyOwner {
        tradingEnabled = enabled;
    }

    function setFees(
        uint256 _liquidityFee,
        uint256 _treasuryFee,
        uint256 _burnFee,
        uint256 _ubiFee,
        uint256 _btcStabFee,
        uint256 _carbonFee,
        uint256 _aiFee
    ) external onlyOwner {
        uint256 total = _liquidityFee + _treasuryFee + _burnFee + _ubiFee + _btcStabFee + _carbonFee + _aiFee;
        require(total <= 2000, "Total fee too high"); // safety cap (20%)
        economicParams = EconomicParams({
            liquidityFee: _liquidityFee,
            treasuryFee: _treasuryFee,
            burnFee: _burnFee,
            ubiFee: _ubiFee,
            btcStabilizationFee: _btcStabFee,
            carbonOffsetFee: _carbonFee,
            aiReserveFee: _aiFee,
            totalFee: total
        });
    }

    function setSwapThreshold(uint256 threshold) external onlyOwner {
        swapThreshold = threshold;
    }

    function lockLiquidity(bool locked) external onlyOwner {
        liquidityLocked = locked;
    }

    function withdrawStabilizationReserve(uint256 amount) external onlyOwner {
        require(amount <= stabilizationReserve, "Insufficient reserve");
        stabilizationReserve -= amount;
        // transfer tokens to owner
        _transfer(address(this), owner(), amount);
    }

    function emergencyWithdrawETH() external onlyOwner {
        uint256 bal = address(this).balance;
        if (bal > 0) payable(owner()).transfer(bal);
    }

    // ================== VIEW HELPERS ==================
    function getTokenomics() external view returns (
        uint256 currentSupply,
        uint256 maxSupply,
        uint256 btcPrice,
        uint256 ubiDistributed,
        uint256 _rewardsPool,
        uint256 stabilization,
        int256 momentum
    ) {
        return (
            totalSupply(),
            MAX_SUPPLY,
            lastBTCPrice,
            totalUBIDistributed,
            rewardsPool,
            stabilizationReserve,
            priceMomentum
        );
    }

    function getHolderInfo(address holder) external view returns (
        uint256 balance,
        uint256 pendingRewards,
        uint256 totalUBIClaimed,
        bool ubiEligible
    ) {
        return (
            balanceOf(holder),
            holderRewards[holder],
            ubiClaims[holder],
            balanceOf(holder) >= minHoldForUBI
        );
    }

    // ================== POOL INIT & RECEIVE ==================
    // Owner creates pool and funds contract with tokens; owner must provide ETH when adding liquidity
    function initializePool() external onlyOwner {
        require(liquidityPool == address(0), "Already initialized");
        liquidityPool = factory.createPair(address(this), WETH);
        isExcludedFromFees[liquidityPool] = true;

        uint256 initialLiquidity = 100_000 * 1e18;
        _mint(address(this), initialLiquidity);
        _approve(address(this), address(router), initialLiquidity);
        // Owner must send ETH and call router.addLiquidityETH via external transaction if desired
    }

    receive() external payable {}
}
