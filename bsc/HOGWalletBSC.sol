// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import '../utils/TransferHelper.sol';
import "./interfaces/IHcSwapV2Router02.sol";

contract HOGWalletBSC is OwnableUpgradeable {
    uint public constant MINIMUM_DELAY = 2 days;
    uint public constant MAXIMUM_DELAY = 3 days;

    mapping(address => bool) private _arbitragerMap; // cross single token to other chain
    mapping(address => bool) private _crossChainTracerMap; // trusted cross-chain operation script
    mapping(address => bool) private _HOGManagerMap; // withdraw funding
    mapping(address => uint256) private _preUnlockAmount;
    mapping(bytes32 => uint256) public timeLockTaskMap;
    uint public CrossNonce;

    mapping(uint => bool) public syncedNonce;

    IHcSwapV2Router02 public hurricaneRouter;

    /* ========== INITIALIZER ========== */

    function initialize() external initializer {
        __Ownable_init();
        CrossNonce = 0;
    }

    /* ========== MODIFIERS ========== */

    modifier onlyArbitrager {
        require(isArbitrager(msg.sender), "HOGWalletBSC: caller is not the arbitrager");
        _;
    }

    modifier onlyTracer {
        require(isTracer(msg.sender), "HOGWalletBSC: caller is not the tracer");
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

    function setHurricaneRouter(address router) public onlyOwner {
        hurricaneRouter = IHcSwapV2Router02(router);
        emit RouterSet(router);
    }

    /* ========== VIEW ========== */

    function isArbitrager(address user) public view returns (bool) {
        return _arbitragerMap[user];
    }

    function isTracer(address user) public view returns (bool) {
        return _crossChainTracerMap[user];
    }

    function getMaxAmountCrossFromAVAX(address token) public view returns (uint256 amount) {
        amount = IERC20(token).balanceOf(address(this));
    }

    function getBlockTimestamp() internal view returns (uint) {
        return block.timestamp;
    }

    /* ========== FUNCTION ========== */

    function registerWithdrawPlan(address token, uint256 amount, uint256 planId) public onlyOwner {
        bytes32 txHash = keccak256(abi.encode(token, amount, planId));
        require(timeLockTaskMap[txHash] == 0, "HOGWalletBSC: txHash existed");
        timeLockTaskMap[txHash] = getBlockTimestamp();
        emit QueueWithdraw(planId, token, amount);
    }

    function cancelWithdrawPlan(address token, uint256 amount, uint256 planId) public onlyOwner {
        bytes32 txHash = keccak256(abi.encode(token, amount, planId));
        require(timeLockTaskMap[txHash] != 0, "HOGWalletBSC: txHash not existed");
        delete timeLockTaskMap[txHash];
        emit CancelWithdraw(planId, token, amount);
    }

    function withdraw(address token, uint256 amount, uint256 planId) public onlyOwner {
        bytes32 txHash = keccak256(abi.encode(token, amount, planId));
        uint256 lockTs = timeLockTaskMap[txHash];
        require(lockTs != 0, "HOGWalletBSC: txHash not existed");
        require(getBlockTimestamp() >= lockTs + MINIMUM_DELAY && getBlockTimestamp() <= lockTs + MAXIMUM_DELAY, "HOGWalletBSC: withdraw plan out of timeRange");

        delete timeLockTaskMap[txHash];
        if (token == address(0)) {
            TransferHelper.safeTransferETH(msg.sender, amount);
        } else {
            TransferHelper.safeTransfer(token, msg.sender, amount);
        }
        emit ExecuteWithdraw(planId, token, amount);
    }

    function crossChainToAVAX(address token, uint256 amount, address target) private onlyArbitrager {
        require(token != address(0), "HOGWalletBSC: token is 0");
        TransferHelper.safeTransferFrom(token, msg.sender, address(this), amount);
        emit Lock(CrossNonce, token, target, amount);
        CrossNonce = CrossNonce + 1;
    }

    function triggerCrossChainFromAVAX(address token, uint256 amount, address user, uint nonce) private onlyTracer {
        require(!syncedNonce[nonce], "HOGWalletBSC: nonce already synced");
        syncedNonce[nonce] = true;
        require(token != address(0), "HOGWalletBSC: token is 0");
        require(amount <= getMaxAmountCrossFromAVAX(token), "HOGWalletBSC: not enough token");
        TransferHelper.safeTransfer(token, user, amount);
        emit Unlock(nonce, token, user, amount);
    }

    function crossChainTo(address token, uint256 amount, address target) public onlyArbitrager {
        if (amount > 0) {
            crossChainToAVAX(token, amount, target);
        }
    }

    function triggerCrossChainFrom(address token, uint256 amount, address user, uint nonce) public onlyTracer {
        triggerCrossChainFromAVAX(token, amount, user, nonce);
    }

    function onCrossSync(IHcSwapV2Router02.CrossAction[] calldata actions) external {
        IHcSwapV2Router02 router = hurricaneRouter;
        require(address(router) != address(0), "HOGWalletBSC: router is 0");
        require(router.isOperator(msg.sender), "HOGWalletBSC: msg.sender is not the operator of hurricaneRouter");
        for (uint i = 0; i < actions.length; i++) {
            if (IERC20(actions[i].tokenA).allowance(address(this), address(router)) < type(uint256).max / 2) {
                TransferHelper.safeApprove(actions[i].tokenA, address(router), type(uint256).max);
            }
            if (IERC20(actions[i].tokenB).allowance(address(this), address(router)) < type(uint256).max / 2) {
                TransferHelper.safeApprove(actions[i].tokenB, address(router), type(uint256).max);
            }
        }
        router.onCrossSync(actions);
    }

    /* ========== EVENT ========== */

    event QueueWithdraw(uint indexed taskId, address indexed token, uint amount);
    event CancelWithdraw(uint indexed taskId, address indexed token, uint amount);
    event ExecuteWithdraw(uint indexed taskId, address indexed token, uint amount);
    // topic: 0xa8d018cceb252c682ff25114c5c821681264845da6b3e5814817538d7718a6fc
    event Unlock(uint indexed nonce, address indexed token, address user, uint amount);
    // topic: 0xc7ace3801a094db0bf2281982c634d18c6dce4faa0651a47bf37be29f7d06c39
    event Lock(uint indexed nonce, address indexed token, address user, uint amount);
    event ArbitragerSet(address indexed user, bool indexed status);
    event TracerSet(address indexed user, bool indexed status);
    event RouterSet(address indexed router);
}
