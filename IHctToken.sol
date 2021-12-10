// SPDX-License-Identifier: GPLv3-or-later

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

interface IHctToken is IERC20 {
    function mint(address to, uint256 amount) external;
    function maxSupply() external view returns (uint256);
}
