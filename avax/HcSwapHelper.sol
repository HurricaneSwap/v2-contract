pragma solidity >=0.6.2;

import './interfaces/IHcSwapAvaxPair.sol';
import './interfaces/IHcSwapAvaxFactory.sol';
import './interfaces/IUniswapV2Factory.sol';
import './libraries/SafeMath.sol';
import './libraries/UniswapV2Library.sol';

contract HcSwapHelper {
    using SafeMath for uint;

    function sqrt(uint y) internal pure returns (uint z) {
        if (y > 3) {
            z = y;
            uint x = y / 2 + 1;
            while (x < z) {
                z = x;
                x = (y / x + x) / 2;
            }
        } else if (y != 0) {
            z = 1;
        }
    }

    function calcMintFee(address _pair) public view returns (uint liquidity) {
        IHcSwapAvaxPair pair = IHcSwapAvaxPair(_pair);
        uint kLast = pair.kLast();
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        if (kLast != 0 && IUniswapV2Factory(pair.factory()).feeTo() != address(0)) {
            uint rootK = sqrt(uint(reserve0).mul(reserve1));
            uint rootKLast = sqrt(kLast);
            if (rootK > rootKLast) {
                uint numerator = pair.totalSupply().mul(rootK.sub(rootKLast));
                uint denominator = (rootK.mul(3) / 2).add(rootKLast);
                liquidity = numerator / denominator;
            }
        }
    }

    function calcReserve(address _pair, address _operator) public view returns (uint reserve0, uint reserve1) {
        IHcSwapAvaxPair pair = IHcSwapAvaxPair(_pair);
        (reserve0, reserve1,) = pair.getReserves();
        uint feeLp = pair.totalSupply().sub(pair.balanceOf(_operator)).sub(1000).add(calcMintFee(_pair));
        (uint amount0, uint amount1) = pair.burnQuery(feeLp);
        reserve0 = reserve0.sub(amount0);
        reserve1 = reserve1.sub(amount1);
    }

    function getReservesWithCross(address factory, address tokenA, address tokenB) public view returns (uint reserveA, uint reserveB, bool cross) {
        (reserveA, reserveB, cross) = UniswapV2Library.getReservesWithCross(factory, tokenA, tokenB);
    }

    function getReserves(address factory, address tokenA, address tokenB) public view returns (uint reserveA, uint reserveB) {
        (reserveA, reserveB) = UniswapV2Library.getReserves(factory, tokenA, tokenB);
    }

    function getAmountOutNoCross(uint amountIn, uint reserveIn, uint reserveOut) public pure returns (uint amountOut) {
        return UniswapV2Library.getAmountOutNoCross(amountIn, reserveIn, reserveOut);
    }

    function getAmountInNoCross(uint amountOut, uint reserveIn, uint reserveOut) public pure returns (uint amountIn) {
        return UniswapV2Library.getAmountInNoCross(amountOut, reserveIn, reserveOut);
    }

    function getAmountOut(uint amountIn, uint reserveIn, uint reserveOut) public pure returns (uint amountOut) {
        return UniswapV2Library.getAmountOut(amountIn, reserveIn, reserveOut);
    }

    function getAmountIn(uint amountOut, uint reserveIn, uint reserveOut) public pure returns (uint amountIn) {
        return UniswapV2Library.getAmountIn(amountOut, reserveIn, reserveOut);
    }

    function getAmountsOut(address factory, uint amountIn, address[] memory path) public view returns (uint[] memory amounts) {
        return UniswapV2Library.getAmountsOut(factory, amountIn, path);
    }

    function getAmountsIn(address factory, uint amountOut, address[] memory path) public view returns (uint[] memory amounts) {
        return UniswapV2Library.getAmountsIn(factory, amountOut, path);
    }
}
