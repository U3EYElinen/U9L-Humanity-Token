// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

/*
  U9L Humanity Token (ETH-stabilized version for Polygon)
  - Total supply: 14,400,000,000 U9L (minted to deployer)
  - Tradable immediately upon deployment
  - Auto-liquidity (swap & add)
  - Multi-fee distribution (liquidity, treasury, burn, UBI, ETH stab, carbon, AI)
  - UBI distribution + claim
  - ETH price feed (Chainlink) for governance/stabilization (Polygon ETH/USD feed)
  - AI governance (momentum-based fee adjustments using ETH price)
  - _update override integrates logic into OpenZeppelin ERC20 transfer flow
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
    uint256 public constant MAX_SUPPLY = 14_400_000_000 * 1e18; // 14.4B
    uint256 public constant INITIAL_MINT = MAX_SUPPLY;         // mint full supply to deployer
    // Chainlink ETH/USD has 8 decimals on most feeds; target = $3,500 => 3500 * 1e8
    uint256 public constant ETH_TARGET_PRICE = 3500 * 1e8;
    uint256 public constant UBI_DISTRIBUTION_CYCLE = 1 days;

    // ================== ECONOMIC PARAMETERS ==================
    struct EconomicParams {
        uint256 liquidityFee;        // per-mille (‰) parts (e.g., 300 => 3.00%)
        uint256 treasuryFee;
        uint256 burnFee;
        uint256 ubiFee;
        uint256 ethStabilizationFee;
        uint256 carbonOffsetFee;
        uint256 aiReserveFee;
        uint256 totalFee;
    }
    EconomicParams public economicParams;

    // ================== STATE VARIABLES ==================
    IDEXRouter public immutable router;
    IUniswapV2Factory public immutable factory;
    AggregatorV3Interface public immutable ethPriceFeed;
    address public immutable WETH;
    address public immutable treasuryWallet;
    address public immutable carbonOffsetWallet;

    uint256 public ethPriceUpdateThreshold = 1 hours;
    uint256 public lastETHPrice;
    uint256 public lastETHTimestamp;
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
    event ETHStabilization(uint256 ethPrice, uint256 amount, bool isMint);
    event AIGovernanceAction(string action, uint256 value);

    // ================== MODIFIERS ==================
    modifier lockTheSwap() {
        require(!inSwap, "Swap in progress");
        inSwap = true;
        _;
        inSwap = false;
    }

    // ================== CONSTRUCTOR ==================
    // Note (Polygon): ETH/USD Chainlink feed (Polygon) example:
    // 0x327e23A4855b6F663a28c5161541d69Af8973302

    constructor(
    address _router,
    address _factory,
    address _ethPriceFeed,
    address _weth,
    address _treasuryWallet,
    address _carbonOffsetWallet
) ERC20("U9L Humanity Token", "U9L") ERC20Permit("U9L Humanity Token") Ownable(msg.sender) ReentrancyGuard() {
    require(_router != address(0), "Invalid router");
    require(_factory != address(0), "Invalid factory");
    require(_ethPriceFeed != address(0), "Invalid ETH feed");
    require(_weth != address(0), "Invalid WETH");
    require(_treasuryWallet != address(0), "Invalid treasury");
    require(_carbonOffsetWallet != address(0), "Invalid carbon wallet");

    router = IDEXRouter(_router);
    factory = IUniswapV2Factory(_factory);
    ethPriceFeed = AggregatorV3Interface(_ethPriceFeed);
    WETH = _weth;
    treasuryWallet = _treasuryWallet;
    carbonOffsetWallet = _carbonOffsetWallet;

    economicParams = EconomicParams({
        liquidityFee: 300,
        treasuryFee: 200,
        burnFee: 100,
        ubiFee: 200,
        ethStabilizationFee: 200,
        carbonOffsetFee: 50,
        aiReserveFee: 50,
        totalFee: 1100
    });

    _mint(msg.sender, INITIAL_MINT);
    isExcludedFromFees[address(this)] = true;
    isExcludedFromFees[msg.sender] = true;
    isExcludedFromFees[treasuryWallet] = true;
    isExcludedFromFees[carbonOffsetWallet] = true;

    (, int256 ethPrice, , , ) = ethPriceFeed.latestRoundData();
    lastETHPrice = uint256(ethPrice);
    lastETHTimestamp = block.timestamp;
    tradingEnabled = true;
}

    // ================== INTERNAL TRANSFER HOOK (_update) ==================
    // Override OpenZeppelin's _update to integrate fees & on-transfer logic.
    function _update(
        address from,
        address to,
        uint256 value
    ) internal virtual override {
        // Allow minting/burning (from==0 or to==0) always.
        // For normal transfers require tradingEnabled (now true by default).
        if (from != address(0) && to != address(0)) {
            require(tradingEnabled, "Trading not enabled");
        }

        // Apply fees only on normal transfers (not mint/burn) and only if not excluded
        uint256 transferAmount = value;
        if (from != address(0) && to != address(0) && !isExcludedFromFees[from] && !isExcludedFromFees[to]) {
            // defensive: ensure totalFee > 0
            uint256 totalF = economicParams.totalFee;
            if (totalF > 0) {
                uint256 fees = (value * totalF) / 1000;
                transferAmount = value - fees;
                _distributeFees(from, fees);
            }
        }

        // Perform the token movement / mint / burn using base implementation
        super._update(from, to, transferAmount);

        // Auto-liquify + periodic actions only for normal transfers and not contract internal ops
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
        uint256 denom = p.totalFee == 0 ? 1 : p.totalFee;

        uint256 liquidityAmount = (fees * p.liquidityFee) / denom;
        uint256 treasuryAmount = (fees * p.treasuryFee) / denom;
        uint256 burnAmount = (fees * p.burnFee) / denom;
        uint256 ubiAmount = (fees * p.ubiFee) / denom;
        uint256 ethStabAmount = (fees * p.ethStabilizationFee) / denom;
        uint256 carbonAmount = (fees * p.carbonOffsetFee) / denom;
        uint256 aiAmount = (fees * p.aiReserveFee) / denom;

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
            rewardsPool += ubiAmount;
            super._update(sender, address(this), ubiAmount);
        }
        if (ethStabAmount > 0) {
            stabilizationReserve += ethStabAmount;
            super._update(sender, address(this), ethStabAmount);
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
    address[] memory path = new address[](2); // ✅ Declare + initialize array
    path[0] = address(this);                  // ✅ Now `path` exists
    path[1] = WETH;                           // ✅ Assign WETH to path[1]

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

    // ================== ETH PEG STABILIZATION ==================
    function _checkETHPeg() internal {
        (, int256 currentETHPriceInt, , uint256 updatedAt, ) = ethPriceFeed.latestRoundData();
        require(block.timestamp - updatedAt < ethPriceUpdateThreshold, "Stale ETH price");

        uint256 currentPrice = uint256(currentETHPriceInt);

        // Adjust only on significant moves (>5%)
        if (lastETHPrice > 0 &&
            (currentPrice > (lastETHPrice * 105) / 100 ||
             currentPrice < (lastETHPrice * 95) / 100)) {

            uint256 targetSupply = (currentPrice * MAX_SUPPLY) / ETH_TARGET_PRICE;

            if (targetSupply > totalSupply()) {
                uint256 mintAmount = targetSupply - totalSupply();
                if (stabilizationReserve >= mintAmount) {
                    stabilizationReserve -= mintAmount;
                    _mint(address(this), mintAmount);
                    emit ETHStabilization(currentPrice, mintAmount, true);
                }
            } else if (targetSupply < totalSupply()) {
                uint256 burnAmount = totalSupply() - targetSupply;
                if (balanceOf(address(this)) >= burnAmount) {
                    _burn(address(this), burnAmount);
                    emit ETHStabilization(currentPrice, burnAmount, false);
                }
            }

            lastETHPrice = currentPrice;
            lastETHTimestamp = block.timestamp;
        }
    }

    function manualSync() external {
        _checkETHPeg();
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
            // Holders mint via claimUBI()
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
        (, int256 currentETHPriceInt, , , ) = ethPriceFeed.latestRoundData();
        uint256 currentPrice = uint256(currentETHPriceInt);

        if (lastETHPrice > 0) {
            int256 change = int256(currentPrice) - int256(lastETHPrice);
            // momentum scaled to roughly +/-100
            priceMomentum = (priceMomentum * 9) / 10 + (change * 100 / int256(lastETHPrice));

            if (priceMomentum > 50) economicParams.ethStabilizationFee = 300;
            else if (priceMomentum < -50) economicParams.ethStabilizationFee = 100;
            else economicParams.ethStabilizationFee = 200;

            economicParams.totalFee =
                economicParams.liquidityFee +
                economicParams.treasuryFee +
                economicParams.burnFee +
                economicParams.ubiFee +
                economicParams.ethStabilizationFee +
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
        uint256 _ethStabFee,
        uint256 _carbonFee,
        uint256 _aiFee
    ) external onlyOwner {
        uint256 total = _liquidityFee + _treasuryFee + _burnFee + _ubiFee + _ethStabFee + _carbonFee + _aiFee;
        require(total <= 2000, "Total fee too high"); // safety cap (20%)
        economicParams = EconomicParams({
            liquidityFee: _liquidityFee,
            treasuryFee: _treasuryFee,
            burnFee: _burnFee,
            ubiFee: _ubiFee,
            ethStabilizationFee: _ethStabFee,
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
        uint256 ethPrice,
        uint256 ubiDistributed,
        uint256 _rewardsPool,
        uint256 stabilization,
        int256 momentum
    ) {
        return (
            totalSupply(),
            MAX_SUPPLY,
            lastETHPrice,
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
