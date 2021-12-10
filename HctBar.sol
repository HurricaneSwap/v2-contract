// SPDX-License-Identifier: GPLv3-or-later

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/utils/math/SafeMath.sol";

// code from xsushi
contract HctBar is ERC20("HctBar", "xHCT") {
    using SafeMath for uint256;
    IERC20 public hct;

    constructor(IERC20 _hct) {
        hct = _hct;
    }

    function enter(uint256 _amount) public {
        uint256 totalHct = hct.balanceOf(address(this));
        uint256 totalShares = totalSupply();
        if (totalShares == 0 || totalHct == 0) {
            _mint(msg.sender, _amount);
        }
        else {
            uint256 what = _amount.mul(totalShares).div(totalHct);
            _mint(msg.sender, what);
        }
        hct.transferFrom(msg.sender, address(this), _amount);
    }

    function leave(uint256 _share) public {
        uint256 totalShares = totalSupply();
        uint256 what = _share.mul(hct.balanceOf(address(this))).div(totalShares);
        _burn(msg.sender, _share);
        hct.transfer(msg.sender, what);
    }
}
