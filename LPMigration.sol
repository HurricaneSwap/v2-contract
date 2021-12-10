// SPDX-License-Identifier: GPLv3-or-later

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IUniswapV2Router01 {
    function factory() external pure returns (address);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint amountADesired,
        uint amountBDesired,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB, uint liquidity);

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address to,
        uint deadline
    ) external returns (uint amountA, uint amountB);
}

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

contract LPMigration is Ownable {
    using SafeERC20 for IERC20;

    address public oldRouter;
    address public newRouter;

    event Migrated(address indexed addr, uint liquidity);

    constructor(address oldRouter_, address newRouter_){
        oldRouter = oldRouter_;
        newRouter = newRouter_;
    }

    function migration(IERC20 lpToken, address tokenA, address tokenB, uint liquidity, uint amountAMin, uint amountBMin, address to, uint deadline) public {
        lpToken.safeTransferFrom(msg.sender, address(this), liquidity);
        IUniswapV2Router01 oldRouter_ = IUniswapV2Router01(oldRouter);
        require(IUniswapV2Factory(oldRouter_.factory()).getPair(tokenA, tokenB) == address(lpToken), "LPMigration::migration: WRONG_LP_TOKEN");
        uint beforeBalanceA = IERC20(tokenA).balanceOf(address(this));
        uint beforeBalanceB = IERC20(tokenB).balanceOf(address(this));

        {
            lpToken.approve(oldRouter, liquidity);
            oldRouter_.removeLiquidity(tokenA, tokenB, liquidity, amountAMin, amountBMin, address(this), deadline);

            uint amountA = IERC20(tokenA).balanceOf(address(this)) - beforeBalanceA;
            uint amountB = IERC20(tokenB).balanceOf(address(this)) - beforeBalanceB;

            IERC20(tokenA).approve(newRouter, amountA);
            IERC20(tokenB).approve(newRouter, amountB);

            IUniswapV2Router01 newRouter_ = IUniswapV2Router01(newRouter);
            newRouter_.addLiquidity(tokenA, tokenB, amountA, amountB, amountAMin, amountBMin, to, deadline);
        }
        emit Migrated(msg.sender, liquidity);

        // refund
        uint remainingAmountA = IERC20(tokenA).balanceOf(address(this));
        uint remainingAmountB = IERC20(tokenB).balanceOf(address(this));
        if (remainingAmountA > beforeBalanceA) {
            IERC20(tokenA).transfer(to, remainingAmountA - beforeBalanceA);
        }
        if (remainingAmountB > beforeBalanceB) {
            IERC20(tokenB).transfer(to, remainingAmountB - beforeBalanceB);
        }
    }
}
