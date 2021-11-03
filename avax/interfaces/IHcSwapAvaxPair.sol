pragma solidity >=0.6.2;

import './IUniswapV2Pair.sol';

interface IHcSwapAvaxPair is IUniswapV2Pair {
    function setCrossPair(bool status_) external;
    function crossPair() external view returns (bool);
    function burnQuery(uint liquidity) external view returns (uint amount0, uint amount1);
}
