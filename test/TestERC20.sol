pragma solidity =0.5.16;

import '../bsc/HcSwapERC20.sol';

contract TestERC20 is HcSwapERC20 {
    constructor(uint _totalSupply) public {
        _mint(msg.sender, _totalSupply);
    }
}
