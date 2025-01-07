// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

contract NutCoin is ERC20, Ownable, ReentrancyGuard {
    enum Fase { Fase1, Fase2, Fase3 }
    Fase private currentFase;

    // Costanti immutabili per risparmiare gas
    uint256 private constant RATE_FASE1_BNB = 5500000000 * 10**18;
    uint256 private constant RATE_FASE2_BNB = 4100000000 * 10**18;
    uint256 private constant RATE_FASE1_USDT = 10000000 * 10**18;
    uint256 private constant RATE_FASE2_USDT = 7500000 * 10**18;
    uint256 private constant TAX_PERCENTAGE = 5;
    uint256 private constant MARKETING_PERCENTAGE = 100;
    uint256 private constant DAILY_SALE_LIMIT = 25;
    uint256 private constant SECONDS_PER_DAY = 86400;

    // Indirizzi immutabili per risparmiare gas
    address private immutable marketingWallet;
    address private constant CREATOR_WALLET = 0x3eAfF22618Df4B5bc462D912CF7dA2fb194215c4;
    address private constant DISTRIBUTION_WALLET = 0x1bF6112131AeBc7808b7f8Ead490261433Cd71Cc;
    address private constant BURN_WALLET = 0x1011cDd4256E5589dDCA10b2bf14011Ee726DD6d;

    // Interfacce per i token
    IERC20 private immutable USDT;

    // Struttura per tracciare le vendite giornaliere
    struct DailySales {
        uint256 amount;
        uint256 timestamp;
    }
    
    mapping(address => DailySales) private dailySales;

    // Eventi
    event PhaseChanged(Fase newPhase);
    event TokensPurchased(address indexed buyer, uint256 amount, bool isBNB);

    constructor(address _usdtAddress) 
        ERC20("NutCoin", "CUM") 
        Ownable(CREATOR_WALLET)
        ReentrancyGuard() 
    {
        USDT = IERC20(_usdtAddress);
        marketingWallet = 0x7Ee547F5e47842fa7b1C4fA2591135bfDd030f0f;

        uint256 totalSupply = 1000000000000000 * 10**18;
        
        unchecked {
            _mint(CREATOR_WALLET, totalSupply * 10 / 100);
            _mint(DISTRIBUTION_WALLET, totalSupply * 40 / 100);
            _mint(BURN_WALLET, totalSupply * 50 / 100);
        }
    }

    function _isProjectWallet(address wallet) private pure returns (bool) {
        return wallet == CREATOR_WALLET ||
               wallet == DISTRIBUTION_WALLET ||
               wallet == BURN_WALLET ||
               wallet == 0x7Ee547F5e47842fa7b1C4fA2591135bfDd030f0f;
    }

    function _checkDailySaleLimit(address seller, uint256 amount) private {
        if (currentFase != Fase.Fase3 || _isProjectWallet(seller)) {
            return;
        }

        DailySales storage sales = dailySales[seller];
        uint256 currentTime = block.timestamp;

        if (currentTime - sales.timestamp >= SECONDS_PER_DAY) {
            sales.amount = 0;
            sales.timestamp = currentTime;
        }

        uint256 userBalance = balanceOf(seller);
        uint256 maxDailyAmount = (userBalance * DAILY_SALE_LIMIT) / 100;
        uint256 newDailyTotal = sales.amount + amount;
        
        require(newDailyTotal <= maxDailyAmount, "Exceeds 25% daily sale limit");
        sales.amount = newDailyTotal;
    }

    function _calculateTax(uint256 amount) private pure returns (uint256) {
        unchecked {
            return amount * TAX_PERCENTAGE / 100;
        }
    }

    function _getRate(bool isBNB) private view returns (uint256) {
        if (currentFase == Fase.Fase1) {
            return isBNB ? RATE_FASE1_BNB : RATE_FASE1_USDT;
        }
        return isBNB ? RATE_FASE2_BNB : RATE_FASE2_USDT;
    }

    function buyWithBNB() external payable nonReentrant {
        require(msg.value > 0, "No BNB sent");
        uint256 amountToBuy = msg.value * _getRate(true) / 10**18;
        _checkDailySaleLimit(msg.sender, amountToBuy);
        _processPurchase(amountToBuy);
        emit TokensPurchased(msg.sender, amountToBuy, true);
    }

    function buyWithUSDT(uint256 usdtAmount) external nonReentrant {
        require(usdtAmount > 0, "No USDT amount");
        uint256 amountToBuy = usdtAmount * _getRate(false) / 10**18;
        
        require(USDT.transferFrom(msg.sender, address(this), usdtAmount), "USDT transfer failed");
        _checkDailySaleLimit(msg.sender, amountToBuy);
        _processPurchase(amountToBuy);
        
        emit TokensPurchased(msg.sender, amountToBuy, false);
    }

    function _processPurchase(uint256 amount) private {
        require(balanceOf(DISTRIBUTION_WALLET) >= amount, "Insufficient tokens");
        uint256 taxAmount = _calculateTax(amount);
        uint256 finalAmount = amount - taxAmount;
        _transfer(DISTRIBUTION_WALLET, msg.sender, finalAmount);
        _transfer(DISTRIBUTION_WALLET, marketingWallet, taxAmount);
    }

    function getCurrentPhase() external view returns (Fase) {
        return currentFase;
    }

    function getMarketingWallet() external view returns (address) {
        return marketingWallet;
    }

    function getDailySales(address user) external view returns (uint256 amount, uint256 lastReset) {
        DailySales memory sales = dailySales[user];
        return (sales.amount, sales.timestamp);
    }

    function advancePhase() external onlyOwner {
        require(currentFase < Fase.Fase3, "Max phase");
        currentFase = Fase(uint8(currentFase) + 1);
        emit PhaseChanged(currentFase);
    }

    function revertPhase() external onlyOwner {
        require(currentFase > Fase.Fase1, "Min phase");
        currentFase = Fase(uint8(currentFase) - 1);
        emit PhaseChanged(currentFase);
    }

    function withdrawBNB() external onlyOwner {
        uint256 balance = address(this).balance;
        require(balance > 0, "No BNB");
        (bool success, ) = owner().call{value: balance}("");
        require(success, "Transfer failed");
    }

    function withdrawUSDT(uint256 amount) external onlyOwner {
        require(USDT.transfer(owner(), amount), "USDT transfer failed");
    }

    receive() external payable {
        revert("Direct ETH not accepted");
    }
}
