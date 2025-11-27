// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/*
🌍 U9L Humanity Token — Visionary Crypto
💎 Auto-Liquidity, BTC Peg, Real-Time Reflections
🚀 Owner Rewards, Deflationary, Human-Centric
*/

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

interface IDEXRouter {
    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint amountIn, uint amountOutMin,
        address[] calldata path, address to,
        uint deadline
    ) external;

    function addLiquidityETH(
        address token, uint amountTokenDesired,
        uint amountTokenMin, uint amountETHMin,
        address to, uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
}

contract U9LHumanity is ERC20, Ownable {
    // ======================== VARIABLES ========================
    uint256 public maxSupply = 1_000_000_000 * 10 ** 18; // 1B cap
    uint256 public liquidityFee = 2;    // 2% liquidity
    uint256 public ownerFee = 2;        // 2% treasury
    uint256 public burnFee = 1;         // 1% burn
    uint256 public reflectionFee = 1;   // 1% to holders
    uint256 public totalFee = liquidityFee + ownerFee + burnFee + reflectionFee;

    address public ownerWallet;
    IDEXRouter public router;
    address public WETH;

    AggregatorV3Interface public btcPriceFeed;

    uint256 public swapThreshold = 10_000 * 10 ** 18;

    bool private inSwap;

    mapping(address => bool) private _isExcludedFromFees;
    mapping(address => uint256) private _holderBalance; // for reflections
    mapping(address => uint256) private _lastDividendAt;

    uint256 public totalDividends;
    uint256 public dividendsPerToken;

    modifier lockTheSwap() {
        inSwap = true;
        _;
        inSwap = false;
    }

    // ======================== CONSTRUCTOR ========================
    constructor(address _router, address _btcPriceFeed, address _ownerWallet) 
        ERC20("U9L Humanity Token", "U9L") Ownable(_ownerWallet) 
    {
        ownerWallet = _ownerWallet;
        router = IDEXRouter(_router);
        btcPriceFeed = AggregatorV3Interface(_btcPriceFeed);
        WETH = 0x0000000000000000000000000000000000000000; // set Polygon WETH address

        uint256 initialMint = 10_000_000 * 10 ** 18;
        _mint(_ownerWallet, initialMint);

        _isExcludedFromFees[_ownerWallet] = true;
        _isExcludedFromFees[address(this)] = true;
    }

    // ======================== OVERRIDE TRANSFER ========================
    function _transfer(address sender, address recipient, uint256 amount) internal override {
        _distributeDividends(sender);

        uint256 fees = 0;
        if (!_isExcludedFromFees[sender] && !_isExcludedFromFees[recipient]) {
            fees = (amount * totalFee) / 100;

            uint256 burnAmount = (fees * burnFee) / totalFee;
            uint256 ownerAmount = (fees * ownerFee) / totalFee;
            uint256 liquidityAmount = (fees * liquidityFee) / totalFee;
            uint256 reflectionAmount = (fees * reflectionFee) / totalFee;

            if (burnAmount > 0) super._burn(sender, burnAmount);
            if (ownerAmount > 0) super._transfer(sender, ownerWallet, ownerAmount);
            if (liquidityAmount + reflectionAmount > 0) 
                super._transfer(sender, address(this), liquidityAmount + reflectionAmount);

            amount -= fees;
            totalDividends += reflectionAmount;
            dividendsPerToken += (reflectionAmount * 10 ** 18) / totalSupply();
        }

        super._transfer(sender, recipient, amount);

        if (!inSwap && balanceOf(address(this)) >= swapThreshold) {
            _swapAndLiquify();
        }
    }

    function _distributeDividends(address holder) internal {
        uint256 owed = dividendsPerToken - _lastDividendAt[holder];
        if (owed > 0) {
            uint256 payout = (_holderBalance[holder] * owed) / 10 ** 18;
            if (payout > 0) _mint(holder, payout);
            _lastDividendAt[holder] = dividendsPerToken;
        }
    }

    // ======================== AUTO-LIQUIDITY ========================
    function _swapAndLiquify() private lockTheSwap {
        uint256 contractBalance = balanceOf(address(this));
        if (contractBalance == 0) return;

        uint256 half = contractBalance / 2;
        uint256 otherHalf = contractBalance - half;

        uint256 initialETH = address(this).balance;

        _swapTokensForETH(half);
        uint256 newETH = address(this).balance - initialETH;

        _addLiquidity(otherHalf, newETH);
    }

    function _swapTokensForETH(uint256 tokenAmount) private {
        address ;
        path[0] = address(this);
        path[1] = WETH;

        _approve(address(this), address(router), tokenAmount);
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            tokenAmount, 0, path, address(this), block.timestamp
        );
    }

    function _addLiquidity(uint256 tokenAmount, uint256 ethAmount) private {
        _approve(address(this), address(router), tokenAmount);
        router.addLiquidityETH{value: ethAmount}(
            address(this), tokenAmount, 0, 0, ownerWallet, block.timestamp
        );
    }

    // ======================== OWNER FUNCTIONS ========================
    function mint(address to, uint256 amount) external onlyOwner {
        require(totalSupply() + amount <= maxSupply, "Max supply reached");
        _mint(to, amount);
    }

    function setFees(uint256 _liquidity, uint256 _owner, uint256 _burn, uint256 _reflection) external onlyOwner {
        liquidityFee = _liquidity;
        ownerFee = _owner;
        burnFee = _burn;
        reflectionFee = _reflection;
        totalFee = liquidityFee + ownerFee + burnFee + reflectionFee;
    }

    function excludeFromFees(address account, bool excluded) external onlyOwner {
        _isExcludedFromFees[account] = excluded;
    }

    function setSwapThreshold(uint256 threshold) external onlyOwner {
        swapThreshold = threshold;
    }

    // ======================== BTC PEG FUNCTIONS ========================
    function btcPrice() public view returns (int) {
        (, int price,,,) = btcPriceFeed.latestRoundData();
        return price; // BTC price in USD 8 decimals
    }

    function adjustSupplyToBTC(uint256 targetTokenPerBTC) external onlyOwner {
        int btc = btcPrice();
        require(btc > 0, "Invalid BTC price");

        uint256 targetSupply = (uint256(btc) * totalSupply()) / targetTokenPerBTC;

        if (targetSupply > totalSupply()) {
            uint256 toMint = targetSupply - totalSupply();
            if (totalSupply() + toMint > maxSupply) toMint = maxSupply - totalSupply();
            _mint(ownerWallet, toMint);
        } else if (targetSupply < totalSupply()) {
            uint256 toBurn = totalSupply() - targetSupply;
            _burn(ownerWallet, toBurn);
        }
    }

    receive() external payable {}
}
