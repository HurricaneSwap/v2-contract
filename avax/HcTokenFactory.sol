pragma solidity =0.5.16;

import './interfaces/IHcTokenFactory.sol';
import './HcToken.sol';

contract HcTokenFactory is IHcTokenFactory {
    address public owner;
    
    modifier onlyOwner(){
        require(msg.sender == owner,"HcSwapFactory:ONLY_OWNER");
        _;
    }

    constructor() public {
        owner = msg.sender;
    }

    event TransferOwnership(address indexed newOwner_);
    event CreateAToken(address indexed originAddress,address indexed avaxAddress);

    function transferOwnership(address newOwner_) onlyOwner public{
        owner = newOwner_;
        emit TransferOwnership(newOwner_);
    }

    function createAToken(string calldata name_,string calldata symbol_,uint8 decimals,address originAddress_) external onlyOwner returns(address token){
        bytes memory bytecode = abi.encodePacked(type(HcToken).creationCode,abi.encode(name_,symbol_,decimals,originAddress_,msg.sender));
        bytes32 salt = keccak256(abi.encodePacked(originAddress_));
        assembly {
            token := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        emit CreateAToken(originAddress_, token);
    }
}