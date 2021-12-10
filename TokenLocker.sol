// SPDX-License-Identifier: GPLv3-or-later

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract TokenLocker is Ownable {
    uint public releaseTime;
    uint public releasePeriod; // release space only days
    uint public releaseTimes;
    address public token;

    struct ReleaseTask {
        uint totalAmount;
        uint stepAmount;
        uint releasedAmount;
        uint nextReleaseTime;
    }

    mapping(address => ReleaseTask) public releaseTasks;

    event AddReleaseTask(address indexed addr, uint amount);
    event Claim(address indexed addr, uint amount);

    constructor(address _token, uint _releaseTime, uint _releasePeriod, uint _releaseTimes) {
        releaseTime = _releaseTime;
        releasePeriod = _releasePeriod;
        token = _token;
        releaseTimes = _releaseTimes;
    }

    function addReleaseTask(address[] memory _addresses, uint[] memory _amounts) public onlyOwner {
        require(_addresses.length == _amounts.length, 'TokenLocker::addReleaseTask WRONG_DATA');
        for (uint i = 0; i < _addresses.length; i++) {
            releaseTasks[_addresses[i]] = ReleaseTask({
                totalAmount: _amounts[i],
                stepAmount: _amounts[i] / releaseTimes,
                releasedAmount: 0,
                nextReleaseTime: releaseTime
            });
            emit AddReleaseTask(_addresses[i], _amounts[i]);
        }
    }

    function claim() public {
        require(block.timestamp >= releaseTime, 'TokenLocker::claim HAVE_NOT_START');
        ReleaseTask storage task = releaseTasks[msg.sender];
        require(task.nextReleaseTime <= block.timestamp, "TokenLocker::claim TOO_EARLY");
        require(task.releasedAmount < task.totalAmount, "TokenLocker::claim NOTHING_CLAIM");
        while (task.nextReleaseTime <= block.timestamp && task.releasedAmount < task.totalAmount) {
            // sub one times
            task.nextReleaseTime += releasePeriod;
            uint releasePart = (task.releasedAmount + task.stepAmount * 2) > task.totalAmount ? task.totalAmount - task.releasedAmount : task.stepAmount;
            IERC20(token).transfer(msg.sender, releasePart);
            task.releasedAmount += releasePart;
            emit Claim(msg.sender, releasePart);
        }
    }

    function emergencyWithdraw(address token_) public onlyOwner {
        IERC20(token_).transfer(msg.sender, IERC20(token_).balanceOf(address(this)));
    }
}
