// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

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
    ) external returns (uint256[] memory amounts);
}

interface IUniswapV2Factory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

contract U9LHumanity is ERC20, ERC20Permit, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ======================== VISION CONSTANTS ========================
    string public constant VISION = "A self-sustaining economic system for all humanity";
    uint256 public constant MAX_SUPPLY = 1_000_000_000 * 1e18; // 1B tokens
    uint256 public constant INITIAL_MINT = 100_000_000 * 1e18; // 10% to treasury
    uint256 public constant BTC_TARGET_PRICE = 50_000 * 1e8; // $50,000 BTC target
    uint256 public constant UBI_DISTRIBUTION_CYCLE = 1 days;

    // ======================== ECONOMIC ENGINE ========================
    struct EconomicParameters {
        uint256 liquidityFee;       
        uint256 treasuryFee;        
        uint256 burnFee;            
        uint256 ubiFee;             
        uint256 btcStabilizationFee;
        uint256 carbonOffsetFee;    
        uint256 aiReserveFee;       
        uint256 totalFee;
    }

    // ======================== STATE VARIABLES ========================
    IDEXRouter public immutable router;
    IUniswapV2Factory public immutable factory;
    AggregatorV3Interface public immutable btcPriceFeed;
    address public immutable WETH;
    address public immutable treasuryWallet;
    address public immutable carbonOffsetWallet;

    EconomicParameters public economicParams;
    uint256 public btcPriceUpdateThreshold = 1 hours;
    uint256 public lastBTCPrice;
    uint256 public lastBTCTimestamp;
    uint256 public stabilizationReserve;
    uint256 public ubiLastDistributed;
    uint256 public totalUBIDistributed;

    uint256 public swapThreshold = 50_000 * 1e18; // 50K tokens
    uint256 public lastLiquifyTimestamp;
    bool public liquidityLocked;
    address public liquidityPool;

    uint256 public rewardsPool;
    mapping(address => uint256) public holderRewards;
    mapping(address => uint256) public lastHolderBalance;

    mapping(address => uint256) public ubiClaims;
    uint256 public ubiPerHolder = 100 * 1e18; 
    uint256 public minHoldForUBI = 1000 * 1e18;

    int256 public priceMomentum; 
    uint256 public lastAICheck;

    bool public tradingEnabled;
    bool public inSwap;
    mapping(address => bool) public isExcludedFromFees;

    // ======================== EVENTS ========================
    event UBIClaimed(address indexed holder, uint256 amount);
    event AutoLiquify(uint256 tokensSwapped, uint256 ethReceived, uint256 liquidityAdded);
    event BTCStabilization(uint256 btcPrice, uint256 adjustmentAmount, bool isMint);
    event CarbonOffset(uint256 amount, uint256 equivalentCO2);
    event AIGovernanceAction(string action, uint256 value);

    // ======================== MODIFIERS ========================
    modifier onlyWhenTradingEnabled() {
        require(tradingEnabled, "Trading not enabled yet");
        _;
    }

    modifier lockTheSwap() {
        require(!inSwap, "Swap in progress");
        inSwap = true;
        _;
        inSwap = false;
    }

    // ======================== CONSTRUCTOR ========================
    constructor(
        address _router,
        address _factory,
        address _btcPriceFeed,
        address _weth,
        address _treasuryWallet,
        address _carbonOffsetWallet
    ) ERC20("U9L Humanity Token", "U9L") ERC20Permit("U9L Humanity Token") {
        require(_router != address(0), "Invalid router");
        require(_factory != address(0), "Invalid factory");
        require(_btcPriceFeed != address(0), "Invalid BTC feed");
        require(_weth != address(0), "Invalid WETH");
        require(_treasuryWallet != address(0), "Invalid treasury");
        require(_carbonOffsetWallet != address(0), "Invalid carbon wallet");

        router = IDEXRouter(_router);
        factory = IUniswapV2Factory(_factory);
        btcPriceFeed = AggregatorV3Interface(_btcPriceFeed);
        WETH = _weth;
        treasuryWallet = _treasuryWallet;
        carbonOffsetWallet = _carbonOffsetWallet;

        economicParams = EconomicParameters({
            liquidityFee: 300,
            treasuryFee: 200,
            burnFee: 100,
            ubiFee: 200,
            btcStabilizationFee: 200,
            carbonOffsetFee: 50,
            aiReserveFee: 50,
            totalFee: 1000
        });

        _mint(treasuryWallet, INITIAL_MINT);

        isExcludedFromFees[address(this)] = true;
        isExcludedFromFees[treasuryWallet] = true;
        isExcludedFromFees[carbonOffsetWallet] = true;

        (, int256 btcPrice, , , ) = btcPriceFeed.latestRoundData();
        lastBTCPrice = uint256(btcPrice);
        lastBTCTimestamp = block.timestamp;
    }

    // ======================== CORE TOKEN FUNCTIONS ========================
    function _update(address from, address to, uint256 amount) internal override {
        if (from != address(0)) lastHolderBalance[from] = balanceOf(from);
        if (to != address(0)) lastHolderBalance[to] = balanceOf(to);
        super._update(from, to, amount);
    }

    function _transfer(address sender, address recipient, uint256 amount) internal override onlyWhenTradingEnabled nonReentrant {
        if (!isExcludedFromFees[sender] && !isExcludedFromFees[recipient]) {
            uint256 fees = (amount * economicParams.totalFee) / 1000;
            amount -= fees;
            _distributeFees(sender, fees);
        }

        super._transfer(sender, recipient, amount);

        if (!inSwap && !liquidityLocked && balanceOf(address(this)) >= swapThreshold && block.timestamp > lastLiquifyTimestamp + 6 hours) {
            lastLiquifyTimestamp = block.timestamp;
            _autoLiquify();
        }

        if (block.timestamp > ubiLastDistributed + UBI_DISTRIBUTION_CYCLE) _distributeUBI();
        if (block.timestamp > lastAICheck + 1 hours) _runAIGovernance();
    }

    function _distributeFees(address sender, uint256 fees) internal {
        uint256 liquidityAmount = (fees * economicParams.liquidityFee) / economicParams.totalFee;
        uint256 treasuryAmount = (fees * economicParams.treasuryFee) / economicParams.totalFee;
        uint256 burnAmount = (fees * economicParams.burnFee) / economicParams.totalFee;
        uint256 ubiAmount = (fees * economicParams.ubiFee) / economicParams.totalFee;
        uint256 btcStabAmount = (fees * economicParams.btcStabilizationFee) / economicParams.totalFee;
        uint256 carbonAmount = (fees * economicParams.carbonOffsetFee) / economicParams.totalFee;
        uint256 aiAmount = (fees * economicParams.aiReserveFee) / economicParams.totalFee;

        if (liquidityAmount > 0) {
            super._transfer(sender, address(this), liquidityAmount);
            stabilizationReserve += liquidityAmount;
        }

        if (treasuryAmount > 0) super._transfer(sender, treasuryWallet, treasuryAmount);
        if (burnAmount > 0) super._burn(sender, burnAmount);
        if (ubiAmount > 0) rewardsPool += ubiAmount;
        if (btcStabAmount > 0) stabilizationReserve += btcStabAmount;
        if (carbonAmount > 0) {
            super._transfer(sender, carbonOffsetWallet, carbonAmount);
            emit CarbonOffset(carbonAmount, carbonAmount / 2);
        }
        if (aiAmount > 0) stabilizationReserve += aiAmount;
    }

    // ======================== AUTO-LIQUIDITY ========================
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

    function _swapTokensForETH(uint256 tokenAmount) private nonReentrant {
        address ;
        path[0] = address(this);
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

    function _addLiquidity(uint256 tokenAmount, uint256 ethAmount) private nonReentrant {
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

    // ======================== BTC PEG ========================
    function _checkBTCPeg() internal {
        (, int256 currentBTCPrice, , uint256 updatedAt, ) = btcPriceFeed.latestRoundData();
        require(block.timestamp - updatedAt < btcPriceUpdateThreshold, "Stale BTC price");
        uint256 currentPrice = uint256(currentBTCPrice);

        if (lastBTCPrice > 0 && (currentPrice > lastBTCPrice * 105 / 100 || currentPrice < lastBTCPrice * 95 / 100)) {
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

    // ======================== UBI ========================
    function _distributeUBI() internal {
        uint256 totalUBI = (totalSupply() * ubiPerHolder) / (1000 * 1e18);
        if (totalUBI > rewardsPool / 5) totalUBI = rewardsPool / 5;

        if (totalUBI > 0 && rewardsPool >= totalUBI) {
            rewardsPool -= totalUBI;
            totalUBIDistributed += totalUBI;
            emit AIGovernanceAction("UBI Distribution", totalUBI);
            ubiLastDistributed = block.timestamp;
        }
    }

    function claimUBI() external {
        require(balanceOf(msg.sender) >= minHoldForUBI, "Insufficient balance");
        require(block.timestamp > ubiLastDistributed, "No UBI available");

        uint256 ubiAmount = ubiPerHolder;
        if (rewardsPool < ubiAmount) ubiAmount = rewardsPool;
        if (ubiAmount > 0) {
            rewardsPool -= ubiAmount;
            _mint(msg.sender, ubiAmount);
            ubiClaims[msg.sender] += ubiAmount;
            emit UBIClaimed(msg.sender, ubiAmount);
        }
    }

    // ======================== AI GOVERNANCE ========================
    function _runAIGovernance() internal {
        (, int256 currentBTCPrice, , , ) = btcPriceFeed.latestRoundData();
        uint256 currentPrice = uint256(currentBTCPrice);

        if (lastBTCPrice > 0) {
            int256 priceChange = int256(currentPrice) - int256(lastBTCPrice);
            priceMomentum = priceMomentum * 9/10 + (priceChange * 100 / lastBTCPrice);

            if (priceMomentum > 50) economicParams.btcStabilizationFee = 300;
            else if (priceMomentum < -50) economicParams.btcStabilizationFee = 100;
            else economicParams.btcStabilizationFee = 200;

            economicParams.totalFee = economicParams.liquidityFee + economicParams.treasuryFee +
                                      economicParams.burnFee + economicParams.ubiFee +
                                      economicParams.btcStabilizationFee +
                                      economicParams.carbonOffsetFee +
                                      economicParams.aiReserveFee;
        }

        lastAICheck = block.timestamp;
    }

    // ======================== REWARDS ========================
    function _updateRewards(address holder) internal {
        if (holder != address(0) && !isExcludedFromFees[holder]) {
            uint256 holderBalance = balanceOf(holder);
            uint256 balanceChange = holderBalance - lastHolderBalance[holder];
            if (balanceChange > 0 && totalSupply() > 0) {
                holderRewards[holder] += (balanceChange * rewardsPool) / totalSupply();
            }
            lastHolderBalance[holder] = holderBalance;
        }
    }

    function claimRewards() external {
        uint256 reward = holderRewards[msg.sender];
        if (reward > 0) {
            holderRewards[msg.sender] = 0;
            _transfer(address(this), msg.sender, reward);
        }
    }

    // ======================== OWNER FUNCTIONS ========================
    function setTradingEnabled(bool enabled) external onlyOwner { tradingEnabled = enabled; }
    function setFees(uint256 l,uint256 t,uint256 b,uint256 u,uint256 btc,uint256 c,uint256 ai) external onlyOwner {
        require(l+t+b+u+btc+c+ai <= 1000,"Total fee too high");
        economicParams = EconomicParameters({liquidityFee:l, treasuryFee:t, burnFee:b, ubiFee:u, btcStabilizationFee:btc, carbonOffsetFee:c, aiReserveFee:ai, totalFee:l+t+b+u+btc+c+ai});
    }
    function setSwapThreshold(uint256 threshold) external onlyOwner { swapThreshold = threshold; }
    function lockLiquidity(bool locked) external onlyOwner { liquidityLocked = locked; }
    function withdrawReserve(uint256 amount) external onlyOwner {
        require(amount <= stabilizationReserve, "Insufficient reserve");
        stabilizationReserve -= amount;
        _transfer(address(this), owner(), amount);
    }
    function emergencyWithdraw() external onlyOwner {
        uint256 ethBalance = address(this).balance;
        if (ethBalance > 0) payable(owner()).transfer(ethBalance);
    }

    // ======================== VIEW FUNCTIONS ========================
    function getTokenomics() external view returns (uint256 currentSupply,uint256 maxSupply,uint256 btcPrice,uint256 ubiDistributed,uint256 _rewardsPool,uint256 carbonOffset,int256 _priceMomentum) {
        return (totalSupply(),MAX_SUPPLY,lastBTCPrice,totalUBIDistributed,rewardsPool,(block.timestamp - lastBTCTimestamp)<btcPriceUpdateThreshold?lastBTCPrice:0,priceMomentum);
    }
    function getHolderInfo(address holder) external view returns (uint256 balance,uint256 pendingRewards,uint256 totalUBIClaimed,bool ubiEligible){
        return (balanceOf(holder),holderRewards[holder],ubiClaims[holder],balanceOf(holder)>=minHoldForUBI);
    }

    // ======================== LIFECYCLE ========================
    function manualSync() external { _checkBTCPeg(); }
    receive() external payable {}

    function initializePool() external onlyOwner {
        require(liquidityPool == address(0), "Already initialized");
        _approve(address(this), address(router), type(uint256).max);
        liquidityPool = factory.createPair(address(this), WETH);
        isExcludedFromFees[liquidityPool] = true;

        uint256 initialLiquidity = 100_000 * 1e18;
        _mint(address(this), initialLiquidity);
        _approve(address(this), address(router), initialLiquidity);
    }
}
