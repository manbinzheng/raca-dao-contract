// SPDX-License-Identifier: GPL-3.0


pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "./interfaces/IPancakeFactory.sol";
import "./interfaces/IPancakePair.sol";
import "./interfaces/IPancakeRouter02.sol";
import "openzeppelin-solidity/contracts/utils/math/SafeMath.sol";

contract RacaDAO is ERC20 {
    using SafeMath for uint256;
    modifier lockSwap {
        _inSwap = true;
        _;
        _inSwap = false;
    }

    uint256 public constant MAX_SUPPLY = uint248(1e14 ether);

    uint256 public constant AMOUNT_DAO = MAX_SUPPLY / 100 * 30;
    uint256 public constant AMOUNT_LP = MAX_SUPPLY / 100 * 20;

    uint256 public constant INVITE_REWARD = 100;

    uint256 internal _buyTax = 5;
    uint256 internal _sellTax = 10;
    uint256 internal _maxSwap = 5;
    uint256 internal _swapFeesAt = 1000 ether;
    bool internal _swapFees = true;

    address payable internal _marketingWallet;
    address payable internal _treasuryWallet;
    address internal _signer;

    IPancakeRouter02 internal _router = IPancakeRouter02(address(0));
    address internal _pair;
    bool internal _inSwap = false;
    bool internal _inLiquidityAdd = false;

    mapping(address => bool) public _minted;
    mapping(address => bool) public _taxExcluded;
    mapping(address => uint256) public _inviteReward;
    mapping(address => uint256) public _inviteRewardTotal;

    constructor(
        address pancakeswapFactory,
        address pancakeswapRouter,
        address payable marketingWallet,
        address payable treasuryWallet,
        address lpAddr,
        address signer
    ) ERC20("RacaDAO", "RDAO")  {
        _addTaxExcluded(msg.sender);
        _addTaxExcluded(address(this));

        _mint(treasuryWallet, AMOUNT_DAO);
        _mint(lpAddr, AMOUNT_LP);

        _marketingWallet = marketingWallet;
        _treasuryWallet = treasuryWallet;
        _signer = signer;

        _router = IPancakeRouter02(pancakeswapRouter);
        IPancakeFactory pancakeswapContract = IPancakeFactory(pancakeswapFactory);
        _pair = pancakeswapContract.createPair(address(this), _router.WETH());
    }

    function isTaxExcluded(address account) public view returns (bool) {
        return _taxExcluded[account];
    }

    function _addTaxExcluded(address account) internal {
        require(!isTaxExcluded(account), "Account must not be excluded");

        _taxExcluded[account] = true;
    }

    function _transfer(
        address sender,
        address recipient,
        uint256 amount
    ) internal override {
        if (isTaxExcluded(sender) || isTaxExcluded(recipient)) {
            super._transfer(sender, recipient, amount);
            return;
        }

        uint256 contractTokenBalance = balanceOf(address(this));
        bool overMinTokenBalance = contractTokenBalance >= _swapFeesAt;

        if (overMinTokenBalance && !_inSwap && sender != _pair && _swapFees) {
            _swap(contractTokenBalance);
        }

        uint256 fees = 0;
        if (sender == _pair) {
            // Buy, apply buy fee schedule
            fees = (amount * _buyTax) / 100;
        } else if (recipient == _pair) {
            // Sell, apply sell fee schedule
            fees = (amount * _sellTax) / 100;
        }

        if (fees > 0) super._transfer(sender, address(this), fees);
        super._transfer(sender, recipient, amount - fees);
    }

    function _swap(uint256 amount) internal lockSwap {
        uint256 maxSwapAmount = (totalSupply() * _maxSwap) / 1000;

        if (amount >= maxSwapAmount) {
            amount = maxSwapAmount;
        }

        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = _router.WETH();

        _approve(address(this), address(_router), amount);

        _router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            amount,
            0,
            path,
            address(this),
            block.timestamp
        );

        uint256 contractETHBalance = address(this).balance;
        if (contractETHBalance > 0) {
            uint256 split = contractETHBalance / 2;
            _marketingWallet.transfer(split);
            _treasuryWallet.transfer(contractETHBalance - split);
        }
    }

    function swapAll() public {
        if (!_inSwap) {
            _swap(balanceOf(address(this)));
        }
    }

    bytes32 constant public MINT_CALL_HASH_TYPE = keccak256("mint(address receiver,uint256 amount)");


    function claim(uint256 amountV, bytes32 r, bytes32 s,address inviter) external {
        uint256 amount = uint248(amountV >> 8);
        uint8 v = uint8(amountV);

        require(totalSupply() + amount <= MAX_SUPPLY, "RacaDAO: Exceed max supply");
        require(!_minted[msg.sender], "RacaDAO: Claimed");

        bytes32 digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32",
                keccak256(abi.encode(MINT_CALL_HASH_TYPE, msg.sender, amount))
        ));

        address signer = ecrecover(digest, v, r, s);

        require(signer == _signer, "RacaDAO: Invalid signer");

        _inviteReward[inviter] = _inviteReward[inviter].add(INVITE_REWARD);

        _inviteRewardTotal[inviter] = _inviteRewardTotal[inviter].add(INVITE_REWARD);

        _minted[msg.sender] = true;
		
        _mint(msg.sender, amount);
    }

    function receiveReward(){
        require(_inviteReward[msg.sender]>0, "RacaDAO: No reward");
        uint256 reward = _inviteReward[msg.sender];
        _inviteReward[msg.sender] = 0
        _mint(msg.sender, reward);
    }

    function invitation(address addr) public view returns (bool) {
        return(_minted[addr]);
    }

    receive() external payable {}
}