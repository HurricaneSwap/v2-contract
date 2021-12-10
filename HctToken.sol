// SPDX-License-Identifier: GPLv3-or-later

pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

contract HctToken is ERC20, Ownable {
    mapping(address => bool) public minter;
    uint public maxSupply;

    constructor(uint _initSupply) ERC20("Hurricane Token", "HCT") {
        _mint(msg.sender, _initSupply);
        maxSupply = 2_000_000_000 * 10 ** decimals();
    }

    event SetMinter(address indexed addr, bool status);

    modifier onlyMinter(){
        require(msg.sender == owner() || minter[msg.sender] == true, "HctToken: only minter");
        _;
    }

    function setMinter(address[] memory addresses_, bool[] memory status_) onlyOwner public {
        require(addresses_.length == status_.length, "HctToken: invalid data");
        for (uint i = 0; i < addresses_.length; i++) {
            minter[addresses_[i]] = status_[i];
            emit SetMinter(addresses_[i], status_[i]);
        }
    }

    function mint(address to_, uint256 amount_) onlyMinter public {
        if(totalSupply() + amount_ > maxSupply){
            amount_ = maxSupply - totalSupply();
        }
        require(amount_ > 0, "HctToken: invalid amount");
        _mint(to_, amount_);
    }
}
