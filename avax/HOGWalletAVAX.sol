// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import '../utils/TransferHelper.sol';
import "./interfaces/IHcToken.sol";

contract HOGWalletAVAX is OwnableUpgradeable {

    mapping(address => bool) private _arbitragerMap; // cross single token to other chain
    mapping(address => bool) private _crossChainTracerMap; // trusted cross-chain operation script
    uint public CrossNonce;

    mapping(uint => bool) public syncedNonce;

    receive() external payable {}

    /* ========== INITIALIZER ========== */

    function initialize() external initializer {
        __Ownable_init();
        CrossNonce = 0;
    }

    /* ========== MODIFIERS ========== */

    modifier onlyArbitrager {
        require(isArbitrager(msg.sender), "HOGWalletAVAX: caller is not the arbitrager");
        _;
    }

    modifier onlyTracer {
        require(isTracer(msg.sender), "HOGWalletAVAX: caller is not the tracer");
        _;
    }

    /* ========== CONTRACT STATE CONTROL ========== */

    function setArbitrager(address _arbitrager, bool _isArbitrager) public onlyOwner {
        if (_isArbitrager) {
            _arbitragerMap[_arbitrager] = true;
        } else {
            delete _arbitragerMap[_arbitrager];
        }
        emit ArbitragerSet(_arbitrager, _isArbitrager);
    }

    function setTracer(address _tracer, bool _isTracer) public onlyOwner {
        if (_isTracer) {
            _crossChainTracerMap[_tracer] = true;
        } else {
            delete _crossChainTracerMap[_tracer];
        }
        emit TracerSet(_tracer, _isTracer);
    }

    /* ========== VIEW ========== */

    function isArbitrager(address user) public view returns (bool) {
        return _arbitragerMap[user];
    }

    function isTracer(address user) public view returns (bool) {
        return _crossChainTracerMap[user];
    }

    /* ========== FUNCTION ========== */

    function withdraw(address token, uint256 amount) public onlyOwner {
        if (token == address(0)) {
            TransferHelper.safeTransferETH(msg.sender, amount);
        } else {
            TransferHelper.safeTransfer(token, msg.sender, amount);
        }
        emit Withdraw(token, msg.sender, amount);
    }

    function withdrawAVAX(uint256 amount) public onlyArbitrager {
        TransferHelper.safeTransferETH(msg.sender, amount);
    }

    function crossChainToBSC(address token, uint256 amount, address target) private onlyArbitrager {
        require(token != address(0), "HOGWalletAVAX: token is 0");
        IHcToken(token).superBurn(msg.sender, amount);
        emit Lock(CrossNonce, token, target, amount);
        CrossNonce = CrossNonce + 1;
    }

    function triggerCrossChainFromBSC(address token, uint256 amount, address user, uint nonce) private onlyTracer {
        require(!syncedNonce[nonce], "HOGWalletAVAX: nonce already synced");
        syncedNonce[nonce] = true;
        require(token != address(0), "HOGWalletAVAX: token is 0");
        IHcToken(token).superMint(user, amount);
        emit Unlock(nonce, token, user, amount);
    }

    function crossChainTo(address token, uint256 amount, address target) public onlyArbitrager {
        if (amount > 0) {
            crossChainToBSC(token, amount, target);
        }
    }

    function triggerCrossChainFrom(address token, uint256 amount, address user, uint nonce) public onlyTracer {
        triggerCrossChainFromBSC(token, amount, user, nonce);
    }

    /* ========== EVENT ========== */

    event Withdraw(address indexed token, address indexed sender, uint amount);
    event Unlock(uint indexed nonce, address indexed token, address user, uint amount);
    event Lock(uint indexed nonce, address indexed token, address user, uint amount);

    event ArbitragerSet(address indexed user, bool indexed status);
    event TracerSet(address indexed user, bool indexed status);
}
