pragma solidity >=0.5.0;

interface IHcTokenFactory {
    function transferOwnership(address newOwner) external;

    function createAToken(string calldata name_,string calldata symbol_,uint8 decimals,address originAddress_) external returns(address token);
}
